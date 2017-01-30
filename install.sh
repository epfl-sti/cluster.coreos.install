#!/bin/bash
#
# Pre- and post-install of EPFL-STI CoreOS cluster nodes
#
# Usage examples:
#
# install.sh install-auto
#
# Workflow:
#
# 1. This script, along with the full cluster.coreos.install Git
#    repository, is downloaded as part of the OS provisioning sequence
#    (e.g. by coreos/provision.erb from GitHub's
#    epflsti/cluster.foreman), and install.sh is executed with
#    some configuration passed through environment variables (see below)
# 2. install.sh installs CoreOS, and does the bare minimum amount of
#    post-install setup to enable both a successful handover to Puppet
#    after reboot, and a manual access through SSH in case of failure.
#    This includes setting up the IPv4 address on a bridge (which
#    would be perilous from Puppet); and running puppet a first time,
#    so that the certificate gets signed. Puppet is then responsible
#    for at least installing itself so that it runs after reboot
#    (see https://github.com/epfl-sti/cluster.coreos.puppet/blob/master/README.md
#    for details on this)
# 3. install.sh does a GET on $PROVISIONING_DONE_URL to let Foreman
#    know that we are ready for show time. Foreman-side, the host
#    transitions into "built" state: its pxelinux configuration is
#    rewritten so that even if the BIOS is still configured to boot
#    through PXE, the boot will proceed using the local disk. Also,
#    the Puppet CA autosign entry is removed.
# 4. The provisioned host reboots into the newly installed CoreOS, and
#    runs Puppet-in-Docker in steady-state mode.
#
# Environment variables (passed by coreos/provision.erb or similar):
#
#  COREOS_FQDN
#    The fully qualified domain name (FQDN) for this node; default
#    to $(hostname -f)
#  COREOS_PRIVATE_IPV4
#    As it says on the tin
#  COREOS_INSTALL_TO_DISK
#    The disk that the install-and-reboot verb should install to (/dev/sda by
#    default)
#  COREOS_INSTALL_URL
#    E.g. http://stable.release.core-os.net/amd64-usr ; passed as the -b flag to
#    /usr/bin/coreos-install
#  PROVISIONING_DONE_URL
#    The URL to wget to to signal Foreman that the provisioning phase is complete
#  PROVISION_GIT_ID
#    The $Id Git tag of coreos/provision.erb at the time the install was run
#  PUPPET_CONF_CA_SERVER
#  PUPPET_CONF_SERVER
#    Extracted from the like-named Foreman global parameters,
#    and used to flesh out /etc/puppet/puppet.conf

set -e -x

if [ -f "/etc/bootstrap-environment" ]; then
    eval "$(sed "s/\([^=]*\)=\(.*\)/: \${\1:='\2'}/g" < /etc/bootstrap-environment)"
fi

: ${COREOS_FQDN:=$(hostname -f)}
: ${COREOS_INSTALL_TO_DISK:=/dev/sda}
: ${COREOS_INSTALL_URL:=http://stable.release.core-os.net/amd64-usr}

#http://git-scm.com/docs/pretty-formats
install_sh_version() {
    (cd "$(dirname "$0")" && git log -1 --format=%ci -- install.sh)
}

ensure_fstab_exists() {
    [ -f "/etc/fstab" ] && return
    echo "LABEL=ROOT	/mnt		ext4 defaults 1 1" > /etc/fstab
    echo "LABEL=USR-A	/mnt/usr	ext4 ro 1 1" >> /etc/fstab
    systemctl daemon-reload
}

mount_mnt() {
    ensure_fstab_exists
    local error
    for attempt in $(seq 1 6); do
        if systemctl start mnt-usr.mount; then return; else error=$?; fi
        sleep 10
    done
    exit $?
}

umount_mnt() {
    ensure_fstab_exists
    systemctl stop mnt.mount
    # Modern kernels appear to re-run udev as soon as the partition table sectors change (e.g., from coreos-install):
    rm /etc/fstab /run/systemd/generator/mnt.mount /run/systemd/generator/mnt-usr.mount
    systemctl daemon-reload
}

install_coreos() {
    # If we are manually re-running a failed install, we want to umount
    # everything before messing with partition tables:
    umount_mnt
    # Zap all volume groups, lest coreos-install fail to BLKRRPART
    # (https://github.com/coreos/bugs/issues/152)
    vgs --noheadings 2>/dev/null | awk '{ print $1}' | \
      xargs -n 1 --no-run-if-empty vgremove -f || true

    /usr/bin/coreos-install -C stable -d "$COREOS_INSTALL_TO_DISK" -b "$COREOS_INSTALL_URL"
}

run_puppet_bootstrap() {
    mount_mnt

    mkdir -p /mnt/etc/puppet
    # We need to talk to the Puppet master for the first time.
    # Note that templates/puppet.conf.erb will basically overwrite this.
    cat >> /mnt/etc/puppet/puppet.conf <<PUPPETCONF
# Bootstrap-time puppet.conf file; will be overridden
[agent]
pluginsync      = true
report          = true
ignoreschedules = true
daemon          = false
ca_server       = $PUPPET_CONF_CA_SERVER
certname        = $COREOS_FQDN
environment     = production
server          = $PUPPET_CONF_SERVER
PUPPETCONF

    set +e -x
    docker rm -f puppet-bootstrap.service || true
    # This is very similar to the ExecStart of templates/puppet.service.erb
    # in epflsti/cluster.coreos.puppet, so that the same Puppet code may run
    # at both bootstrap and production stages.
    docker run --name puppet-bootstrap.service \
           --net=host --privileged \
           -v /mnt:/opt/root \
           -v /dev:/dev \
           -v /mnt/etc/systemd:/etc/systemd \
           -v /mnt/etc/puppet:/etc/puppet \
           -v /mnt/var/lib/puppet:/var/lib/puppet \
           -v /run/systemd:/run/systemd \
           -v /home/core:/home/core \
           -v /mnt/usr/bin/systemctl:/usr/bin/systemctl:ro \
           -v /mnt/lib64:/lib64:ro \
           -v /mnt/usr/lib64/systemd:/usr/lib64/systemd \
           -v /mnt/usr/lib/systemd:/usr/lib/systemd \
           -e FACTER_ipaddress=$COREOS_PRIVATE_IPV4 \
           -e FACTER_lifecycle_stage=bootstrap \
           -e FACTER_provision_git_id="$PROVISION_GIT_ID" \
           -e FACTER_install_sh_version="$(install_sh_version)" \
           epflsti/cluster.coreos.puppet:latest \
           agent --test
    
    exitcode=$?
    case "$exitcode" in
        0|2) : ;;
        *) echo >&2 "Puppet agent in Docker exited with status $exitcode"
           exit $exitcode ;;
    esac
    set -e -x
}

foreman_built() {
    wget -q -O /dev/null --no-check-certificate "$PROVISIONING_DONE_URL"
}

while [ -n "$1" ]; do case "$1" in
    mount)
        mount_mnt
        shift ;;
    umount)
        umount_mnt
        shift ;;
    puppetclean)
        rm -rf /mnt/var/lib/puppet/lib/
        shift ;;
    puppet)
        run_puppet_bootstrap
        shift ;;
    foreman-built)
        foreman_built
        shift ;;
    reboot)
        reboot
        shift ;;
    install-and-wait)
        install_coreos
        run_puppet_bootstrap
        umount_mnt
        shift ;;

    install-auto)
        install_coreos
        run_puppet_bootstrap
        umount_mnt
        foreman_built
        reboot
        shift ;;


    *)
        set +x
        echo >&2 "Unknown verb: $1"
        exit 2
        ;;
esac; done

exit 0

#!/bin/bash
#
# Pre- and post-install CoreOS cluster nodes
#
# Usages:
#
# install.sh install-and-reboot
# install.sh postinstall
#
# Environment variables:
#
#  COREOS_FQDN
#    The fully qualified domain name (FQDN) for this node
#  COREOS_PRIVATE_IPV4
#    As it says on the tin
#  COREOS_PRIMARY_NETWORK_INTERFACE
#    The CoreOS-style name of the primary network interface, e.g.
#    enp1s0f0 or some such
#  COREOS_INSTALL_TO_DISK
#    The disk that the install-and-reboot verb should install to (/dev/sda by
#    default)
#  COREOS_INSTALL_URL
#    E.g. http://stable.release.core-os.net/amd64-usr ; passed as the -b flag to
#    /usr/bin/coreos-install
#  PROVISIONING_DONE_URL
#    The URL to wget to to signal Foreman that the provisioning phase is complete
#  PROVISION_GIT_ID
#    The $Id$ of coreos/provision.erb at the time the install was run
#  PUPPET_CONF_CA_SERVER
#  PUPPET_CONF_SERVER
#  GATEWAY_VIP
#  DNS_VIP
#    Extracted from the like-named Foreman global parameters.
#    PUPPET_CONF_CA_SERVER and PUPPET_CONF_SERVER (e.g.
#    puppetmaster.ne.cloud.epfl.ch) are used to flesh out
#    /etc/puppet/puppet.conf. GATEWAY_VIP and
#    DNS_VIP need to be known before Puppet runs, so as to
#    download the Puppet image in the first place.

set -e -x

: ${COREOS_INSTALL_TO_DISK:=/dev/sda}
: ${COREOS_INSTALL_URL:=http://stable.release.core-os.net/amd64-usr}

cat_cloud_config() {
    cat <<CLOUD_CONFIG_PREAMBLE
#cloud-config
hostname: $COREOS_FQDN
coreos:
  fleet:
    public-ip: $COREOS_PRIVATE_IPV4
  units:
CLOUD_CONFIG_PREAMBLE

# etcd and the fleet metadata are configured by Puppet, yet started by
# the CoreOS boot sequence. This lets quorum members reboot safely if
# Puppet is unavailable. (Nothing particularly bad happens if etcd2
# starts unconfigured; it just bails out.)

cat <<BASE_UNITS
          - name: etcd2.service
            command: start
          - name: fleet.service
            command: start
BASE_UNITS

# https://coreos.com/os/docs/latest/customizing-docker.html

cat <<DOCKER_UNIT_ON_STEROIDS
          - name: docker-tcp.socket
            command: start
            enable: yes
            content: |
              [Unit]
              Description=Docker Socket for the API
              
              [Socket]
              ListenStream=2375
              BindIPv6Only=both
              Service=docker.service
              
              [Install]
              WantedBy=sockets.target
          - name: enable-docker-tcp.service
            command: start
            content: |
              [Unit]
              Description=Enable the Docker Socket for the API
              
              [Service]
              Type=oneshot
              ExecStart=/usr/bin/systemctl enable docker-tcp.socket
          - name: docker.service
            drop-ins:
              - name: 10-ipv6.conf
                content: |
                  [Service]
                  Environment="DOCKER_OPTS=--ipv6"
DOCKER_UNIT_ON_STEROIDS

local puppet_in_docker_args="$(puppet_in_docker_args)"

cat <<PUPPET_BEFORE_REBOOT
          - name: puppet.service
            command: start
            content: |
              [Unit]
              Description=Puppet in Docker
              After=docker.service
              Requires=docker.service
              
              [Service]
              ExecStartPre=/bin/bash -c '/usr/bin/docker inspect %n &> /dev/null && /usr/bin/docker rm %n || :'
              ExecStart=/usr/bin/docker run --name %n $puppet_in_docker_args agent --no-daemonize --logdest=console --environment=production
              RestartSec=5s
              Restart=always
            
              [Install]
              WantedBy=multi-user.target
PUPPET_BEFORE_REBOOT

# I'm pretty sure this is useless:
#           - name: puppet-bootstrap.service
#             runtime: true
#             content: |
#               [Unit]
#               Description=Ensure Puppet runs once before reboot
#               After=puppet.service system-networkd.service
#               Requires=puppet.service
#               [Service]
#               Type=oneshot
#               ExecStart=/usr/bin/docker exec -it puppet.service puppet agent -t

cat <<NETWORK_CONFIG

          - name: ethbr4.netdev
            content: |
              [NetDev]
              Name=ethbr4
              Kind=bridge
          - name: 50-ethbr4-internal.network
            content: |
              # Network configuration of ethbr4 for an internal node.
              # Overridden by 40-ethbr4-nogateway.network when that
              # symlink exists.
              [Match]
              Name=ethbr4
 
              [Network]
              Address=$COREOS_PRIVATE_IPV4/24
              Gateway=$GATEWAY_VIP
              DNS=$DNS_VIP
          - name: 00-$COREOS_PRIMARY_NETWORK_INTERFACE.network
            content: |
              [Match]
              Name=$COREOS_PRIMARY_NETWORK_INTERFACE
 
              [Network]
              DHCP=no
              Bridge=ethbr4
          - name: systemd-networkd.service
            command: stop
          - name: cleanup-DHCP-assigned-addresses.service
            runtime: true
            command: start
            content: |
              [Service]
              Type=oneshot
              ExecStart=/usr/bin/ip addr flush dev $COREOS_PRIMARY_NETWORK_INTERFACE
          - name: systemd-networkd.service
            command: start
  write_files:
      - path: /etc/systemd/network/40-ethbr4-nogateway.opt-network
        content: |
          # Network configuration for ethbr4 without a default route.
          # Overrides 50-ethbr4-internal.network on gateway nodes.
          [Match]
          Name=ethbr4

          [Network]
          Address=$COREOS_PRIVATE_IPV4/24
          DNS=$DNS_VIP
 
NETWORK_CONFIG

# Post-bootstrap SSH keys are managed with Puppet.

}


install_done() {
    [ -d "/etc/coreos" ]
}

puppet_in_docker_args() {
    local MNT ROOT
    if install_done; then 
        ROOT=/
        MNT=
    else 
        ROOT=/mnt
        MNT=/mnt
    fi

(
    cat <<ARGS
          --net=host
          --privileged
          -v $ROOT:/opt/root
          -v $MNT/etc/systemd:/etc/systemd
          -v $MNT/etc/puppet:/etc/puppet
          -v $MNT/var/lib/puppet:/var/lib/puppet
          -v $MNT/home/core:/home/core
          -v $MNT/etc/os-release:/etc/os-release:ro
          -v $MNT/etc/lsb-release:/etc/lsb-release:ro
          -v $MNT/etc/coreos:/etc/coreos:rw
          -v /run:/run:ro
          -v $MNT/usr/bin/systemctl:/usr/bin/systemctl:ro
          -v $MNT/lib64:/lib64:ro
          -v $MNT/sys/fs/cgroup:/sys/fs/cgroup:ro
          -v $MNT/etc/puppet/puppet.conf:/etc/puppet/puppet.conf:ro
          -v /dev/ipmi0:/dev/ipmi0
          -e FACTER_ipaddress=$COREOS_PRIVATE_IPV4

ARGS
    if install_done; then
        # Make /media/staging available (the path where the to-be-rebooted-into
        # version of CoreOS is being staged, I guess)
        echo "-v /media/staging:/opt/staging"
    fi

    echo "epflsti/cluster.coreos.puppet:latest"
) | tr '\n' ' '
}

install_and_reboot() {
    cat_cloud_config > /home/core/cloud-config.yml
    chown core:core /home/core/cloud-config.yml
    chmod 600 /home/core/cloud-config.yml

    # Zap all volume groups, lest coreos-install fail to BLKRRPART
    # (https://github.com/coreos/bugs/issues/152)
    vgs --noheadings 2>/dev/null | awk '{ print $1}' | xargs -n 1 vgremove -f || true

    /usr/bin/coreos-install -C stable -d "$COREOS_INSTALL_TO_DISK" -c /home/core/cloud-config.yml -b "$COREOS_INSTALL_URL"
    # TODO: do some ZFS here!

       
    # Load modules right away, so that Puppet may tweak IPMI
    modprobe ipmi_si
    modprobe ipmi_devintf
 
    mkdir -p /mnt/etc/puppet
    cat >> /mnt/etc/puppet/puppet.conf <<PUPPETCONF
# My default puppet.conf file
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
 
    set +e
    docker run --name puppet-bootstrap $(puppet_in_docker_args) agent -t
    exitcode=$?
    case "$exitcode" in
        0|2) : ;;
        *) echo >&2 "Puppet agent in Docker exited with status $exitcode"
           exit $exitcode ;;
    esac
    set -e
 
    # Create this file before next reboot to simplify post-reboot bootstrap
    mkdir -p /mnt/etc/modules-load.d
    cat >> /mnt/etc/modules-load.d/ipmi.conf <<"IPMI_CONF"
# Load IPMI modules
ipmi_si
ipmi_devintf
IPMI_CONF
      
    # All done
    umount /mnt/usr
    umount /mnt
    wget -q -O /dev/null --no-check-certificate $PROVISIONING_DONE_URL
    reboot
}

case "$1" in
    cat-cloud-config)
        # For debug
        cat_cloud_config;;
    install-and-reboot)
        install_and_reboot;;
esac
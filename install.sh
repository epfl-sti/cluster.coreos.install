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

: ${COREOS_INSTALL_DISK:=/dev/sda}
: ${COREOS_INSTALL_URL:=http://stable.release.core-os.net/amd64-usr}

case "$1" in
    install-and-reboot)
        install_and_reboot;;
esac
        
    

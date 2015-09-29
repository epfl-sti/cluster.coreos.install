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
#

case "$1" in
    install-and-reboot)
        install_and_reboot;;
esac
        
    

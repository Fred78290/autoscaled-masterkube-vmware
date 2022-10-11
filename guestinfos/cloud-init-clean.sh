#!/bin/bash
#[ -f /etc/cloud/cloud.cfg.d/50-curtin-networking.cfg ] && rm /etc/cloud/cloud.cfg.d/50-curtin-networking.cfg
#rm /etc/netplan/*
#rm /etc/machine-id
#cloud-init clean
#rm /var/log/cloud-ini*
#rm /var/log/syslog
cloud-init clean
cloud-init clean -l 
shutdown -h now

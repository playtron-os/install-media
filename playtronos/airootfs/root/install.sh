#! /bin/bash

set -e

if [ $EUID -ne 0 ]; then
	echo "$(basename $0) must be run as root"
	exit 1
fi

device_list=()
device_output=`lsblk --list -n -o name,model,size,type | grep disk | tr -s ' ' '\t'`

while read -r line; do
	name=/dev/`echo "$line" | cut -f 1`
	model=`echo "$line" | cut -f 2`
	size=`echo "$line" | cut -f 3`
	device_list+=($name)
	device_list+=("$model ($size)")
done <<< "$device_output"

DISK=$(whiptail --nocancel --menu "Choose a disk to install to:" 20 50 5 "${device_list[@]}" 3>&1 1>&2 2>&3)

if ! (whiptail --yesno "WARNING: $DISK will now be formatted. All data on the disk will be lost. Do you wish to proceed?" 10 50); then
    if (whiptail --yesno --yes-button "Reboot" --no-button "Open command prompt" "Installation cancelled" 10 70); then
        reboot
    fi

    exit 1
fi

(zstd -c -d *.img.zst | pv -n -s 8G | dd of=${DISK} bs=128M conv=notrunc,noerror) 2>&1 | whiptail --gauge "Installing PlaytronOS..." 10 70 0
sync

MSG="Installation failed"
if [ "$?" == "0" ]; then
    MSG="Installation completed"
fi

if (whiptail --yesno --yes-button "Reboot" --no-button "Open command prompt" "${MSG}" 10 70); then
    reboot
fi

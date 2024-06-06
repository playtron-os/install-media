#! /bin/bash

set -e

if [ $EUID -ne 0 ]; then
	echo "$(basename $0) must be run as root"
	exit 1
fi


OS_NAME=PlaytronOS
DEVICE_VENDOR=$(cat /sys/devices/virtual/dmi/id/sys_vendor)
DEVICE_PRODUCT=$(cat /sys/devices/virtual/dmi/id/product_name)
DEVICE_CPU=$(lscpu | grep Vendor | cut -d':' -f2 | xargs echo -n)

get_boot_disk() {
	local current_boot_id=$(efibootmgr | grep BootCurrent | head -1 | cut -d':' -f 2 | tr -d ' ')
	local boot_disk_info=$(efibootmgr | grep "Boot${current_boot_id}" | head -1)
	local part_uuid=$(echo $boot_disk_info | cut -d',' -f3 | head -1 | sed -e 's/^0x//')
	local part=$(blkid | grep $part_uuid | cut -d':' -f1 | head -1 | sed -e 's,/dev/,,')
	local part_path=$(readlink "/sys/class/block/$part")
	basename `dirname $part_path`
}

get_disk_model_override() {
	local device=$1
	grep "${DEVICE_VENDOR}:${DEVICE_PRODUCT}:${DEVICE_CPU}:${device}" overrides | cut -f2- | xargs echo -n
}

get_disk_human_description() {
	local name=$1
	local size=$(lsblk --list -n -o name,size | grep "$name " | cut -d' ' -f2- | xargs echo -n)

	if [ "$size" = "0B" ]; then
		return
	fi

	local model=$(get_disk_model_override $name | xargs echo -n)
	if [ -z "$model" ]; then
		model=$(lsblk --list -n -o name,model | grep "$name " | cut -d' ' -f2- | xargs echo -n)
	fi

	local vendor=$(lsblk --list -n -o name,vendor | grep "$name " | cut -d' ' -f2- | xargs echo -n)
	local transport=$(lsblk --list -n -o name,tran | grep "$name " | cut -d' ' -f2- | \
		sed -e 's/usb/USB/' | \
		sed -e 's/nvme/Internal/' | \
		sed -e 's/ata/Internal/' | \
		sed -e 's/sata/Internal/' | \
		sed -e 's/mmc/SD card/' | \
		xargs echo -n)
	echo "[${transport}] ${vendor} ${model:=Unknown model} ($size)" | xargs echo -n
}

# a key/value store using an array
# odd number indexes are keys, even number indexes are values
device_list=()

device_output=$(lsblk --list -n -o name,type | grep disk | grep -v zram | grep -v `get_boot_disk`)
while read -r line; do
	name=$(echo "$line" | cut -d' ' -f1 | xargs echo -n)
	description=$(get_disk_human_description $name)
	if [ -z "$description" ]; then
		continue
	fi
	device_list+=($name)
	device_list+=("$description")
done <<< "$device_output"


if [ "${#device_list[@]}" -gt 2 ]; then
	DISK=$(whiptail --nocancel --menu "Choose a disk to install $OS_NAME on:" 20 70 5 "${device_list[@]}" 3>&1 1>&2 2>&3)
else
	DISK=${device_list[0]}
fi

DISK_DESC=$(get_disk_human_description $DISK)

if ! (whiptail --yesno --defaultno "\
WARNING: $OS_NAME will now be installed and all data on the following disk will be lost:\n\n\
	$DISK - $DISK_DESC\n\n\
Do you wish to proceed?" 15 70); then
    if (whiptail --yesno --yes-button "Power off" --no-button "Open command prompt" "Installation cancelled" 10 70); then
        poweroff
    fi

    exit 1
fi

(zstd -c -d *.img.zst | pv -n -s 8G | dd of=/dev/${DISK} bs=128M conv=notrunc,noerror) 2>&1 | whiptail --gauge "Installing $OS_NAME..." 10 70 0
sync

MSG="Installation failed"
if [ "$?" == "0" ]; then
    MSG="Installation completed"
    efibootmgr --delete-bootnum --label $OS_NAME || true
    efibootmgr --create --disk /dev/${DISK} --part 1 --loader \\EFI\\fedora\\shim.efi --label $OS_NAME
fi

if (whiptail --yesno --yes-button "Reboot" --no-button "Open command prompt" "${MSG}" 10 70); then
    reboot
fi

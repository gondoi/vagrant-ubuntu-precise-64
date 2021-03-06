#!/bin/bash

exists() {
  if command -v $1 &>/dev/null
  then
    return 0
  else
    return 1
  fi
}

# make sure we have dependencies 
hash mkisofs 2>/dev/null || { echo >&2 "ERROR: mkisofs not found.  Aborting."; exit 1; }

BOX="ubuntu-precise-64"

# what os are we running?
OS=$(uname -s)

# get the correct md5 tool
if exists md5;
then
  MD5="md5 -r"
else
  MD5="md5sum"
fi

# location, location, location
FOLDER_BASE=`pwd`
FOLDER_BUILD="${FOLDER_BASE}/build"
FOLDER_VBOX="${FOLDER_BUILD}/vbox"
FOLDER_ISO="${FOLDER_BUILD}/iso"
FOLDER_ISO_CUSTOM="${FOLDER_BUILD}/iso/custom"
FOLDER_ISO_INITRD="${FOLDER_BUILD}/iso/initrd"
FOLDER_ISO_MOUNT="${FOLDER_BUILD}/mount"

# let's make sure they exist
mkdir -p "${FOLDER_BUILD}"
mkdir -p "${FOLDER_VBOX}"
mkdir -p "${FOLDER_ISO_CUSTOM}"
mkdir -p "${FOLDER_ISO_INITRD}"

# let's make sure they're empty
echo "Cleaning Custom build directories..."
chmod -R u+w "${FOLDER_ISO_CUSTOM}"
rm -rf "${FOLDER_ISO_CUSTOM}"
mkdir -p "${FOLDER_ISO_CUSTOM}"
if [ "$OS" == "Linux" ];
then
  sudo chown -R ${USER}:${USER} "${FOLDER_ISO_INITRD}"
fi
chmod -R u+w "${FOLDER_ISO_INITRD}"
rm -rf "${FOLDER_ISO_INITRD}"
mkdir -p "${FOLDER_ISO_INITRD}"
rm -rf "${FOLDER_ISO_MOUNT}"
mkdir -p "${FOLDER_ISO_MOUNT}"

ISO_URL="http://releases.ubuntu.com/precise/ubuntu-12.04-alternate-amd64.iso"
ISO_FILENAME="${FOLDER_ISO}/`basename ${ISO_URL}`"
ISO_MD5="9fcc322536575dda5879c279f0b142d7"
INITRD_FILENAME="${FOLDER_ISO}/initrd.gz"

if [ "$OS" == "Linux" ];
then
  ISO_GUESTADDITIONS="/usr/share/virtualbox/VBoxGuestAdditions.iso"
  CPIO="sudo cpio"
elif [ "$OS" == "Darwin" ];
then
  ISO_GUESTADDITIONS="/Applications/VirtualBox.app/Contents/MacOS/VBoxGuestAdditions.iso"
  CPIO="cpio"
fi

# download the installation disk if you haven't already or it is corrupted somehow
if [ ! -e "${ISO_FILENAME}" ] 
then
   echo "Downloading ubuntu-12.04-alternate-amd64.iso ..."
   curl --output "${ISO_FILENAME}" -L "${ISO_URL}"
else
  # make sure download is right...
  echo "Checking ISO hash ..."
  ISO_HASH=`${MD5} "${ISO_FILENAME}" |awk {'print $1'}`
  if [ "${ISO_MD5}" != "${ISO_HASH}" ]; then
    echo "ERROR: MD5 does not match. Got ${ISO_HASH} instead of ${ISO_MD5}. Aborting."
    exit 1
  fi
  echo "MD5 hash matches. Continuing ..."
fi

# customize it
echo "Creating Custom ISO"
if [ ! -e "${FOLDER_ISO}/custom.iso" ]; then

  echo "Extracting downloaded ISO ..."
  if [ "$OS" == "Linux" ];
  then
    sudo mount -o loop ${ISO_FILENAME} ${FOLDER_ISO_MOUNT}
    sudo cp -r ${FOLDER_ISO_MOUNT}/* ${FOLDER_ISO_CUSTOM}
    sudo cp -r ${FOLDER_ISO_MOUNT}/.disk ${FOLDER_ISO_CUSTOM}
    sudo umount ${FOLDER_ISO_MOUNT}
    sudo chown -R ${USER}:${USER} ${FOLDER_ISO_CUSTOM}
  elif [ "$OS" == "Darwin" ];
  then
    tar -C "${FOLDER_ISO_CUSTOM}" -xf "${ISO_FILENAME}"
  fi

  # backup initrd.gz
  echo "Backing up current init.rd ..."
  chmod u+w "${FOLDER_ISO_CUSTOM}/install" "${FOLDER_ISO_CUSTOM}/install/initrd.gz"
  mv "${FOLDER_ISO_CUSTOM}/install/initrd.gz" "${FOLDER_ISO_CUSTOM}/install/initrd.gz.org"

  # stick in our new initrd.gz
  echo "Installing new initrd.gz ..."
  cd "${FOLDER_ISO_INITRD}"
  gunzip -c "${FOLDER_ISO_CUSTOM}/install/initrd.gz.org" | ${CPIO} -id
  cd "${FOLDER_BASE}"
  cp preseed.cfg "${FOLDER_ISO_INITRD}/preseed.cfg"
  cd "${FOLDER_ISO_INITRD}"
  find . | ${CPIO} --create --format='newc' | gzip  > "${FOLDER_ISO_CUSTOM}/install/initrd.gz"

  # clean up permissions
  echo "Cleaning up Permissions ..."
  chmod u-w "${FOLDER_ISO_CUSTOM}/install" "${FOLDER_ISO_CUSTOM}/install/initrd.gz" "${FOLDER_ISO_CUSTOM}/install/initrd.gz.org"

  # replace isolinux configuration
  echo "Replacing isolinux config ..."
  cd "${FOLDER_BASE}"
  chmod u+w "${FOLDER_ISO_CUSTOM}/isolinux" "${FOLDER_ISO_CUSTOM}/isolinux/isolinux.cfg"
  rm "${FOLDER_ISO_CUSTOM}/isolinux/isolinux.cfg"
  cp isolinux.cfg "${FOLDER_ISO_CUSTOM}/isolinux/isolinux.cfg"  
  chmod u+w "${FOLDER_ISO_CUSTOM}/isolinux/isolinux.bin"

  # add late_command script
  echo "Add late_command script ..."
  chmod u+w "${FOLDER_ISO_CUSTOM}"
  cp "${FOLDER_BASE}/late_command.sh" "${FOLDER_ISO_CUSTOM}"
  
  echo "Running mkisofs ..."
  mkisofs -r -V "Custom Ubuntu Install CD" \
    -cache-inodes -quiet \
    -J -l -b isolinux/isolinux.bin \
    -c isolinux/boot.cat -no-emul-boot \
    -boot-load-size 4 -boot-info-table \
    -o "${FOLDER_ISO}/custom.iso" "${FOLDER_ISO_CUSTOM}"

fi

echo "Creating VM Box..."
# create virtual machine
if ! VBoxManage showvminfo "${BOX}" >/dev/null 2>/dev/null; then
  VBoxManage createvm \
    --name "${BOX}" \
    --ostype Ubuntu_64 \
    --register \
    --basefolder "${FOLDER_VBOX}"

  VBoxManage modifyvm "${BOX}" \
    --memory 360 \
    --boot1 dvd \
    --boot2 disk \
    --boot3 none \
    --boot4 none \
    --vram 12 \
    --pae off \
    --rtcuseutc on

  VBoxManage storagectl "${BOX}" \
    --name "IDE Controller" \
    --add ide \
    --controller PIIX4 \
    --hostiocache on

  VBoxManage storageattach "${BOX}" \
    --storagectl "IDE Controller" \
    --port 1 \
    --device 0 \
    --type dvddrive \
    --medium "${FOLDER_ISO}/custom.iso"

  VBoxManage storagectl "${BOX}" \
    --name "SATA Controller" \
    --add sata \
    --controller IntelAhci \
    --sataportcount 1 \
    --hostiocache off

  VBoxManage createhd \
    --filename "${FOLDER_VBOX}/${BOX}/${BOX}.vdi" \
    --size 40960

  VBoxManage storageattach "${BOX}" \
    --storagectl "SATA Controller" \
    --port 0 \
    --device 0 \
    --type hdd \
    --medium "${FOLDER_VBOX}/${BOX}/${BOX}.vdi"

  VBoxManage startvm "${BOX}" \
    --type headless
#  VBoxHeadless --startvm "${BOX}" &

  echo -n "Waiting for installer to finish "
  while VBoxManage list runningvms | grep "${BOX}" >/dev/null; do
    sleep 20
    echo -n "."
  done
  echo ""

  # Forward SSH
  VBoxManage modifyvm "${BOX}" \
    --natpf1 "guestssh,tcp,,2222,,22"

  # Attach guest additions iso
  VBoxManage storageattach "${BOX}" \
    --storagectl "IDE Controller" \
    --port 1 \
    --device 0 \
    --type dvddrive \
    --medium "${ISO_GUESTADDITIONS}"

  VBoxManage startvm "${BOX}" \
    --type headless
#  VBoxHeadless --startvm "${BOX}" &

  # get private key
  curl --output "${FOLDER_BUILD}/id_rsa" "https://raw.github.com/mitchellh/vagrant/master/keys/vagrant"
  chmod 600 "${FOLDER_BUILD}/id_rsa"

  # install virtualbox guest additions
  ssh -i "${FOLDER_BUILD}/id_rsa" -o UserKnownHostsFile=/dev/null -o StrictHostKeyChecking=no -p 2222 vagrant@127.0.0.1 "sudo mount /dev/cdrom /media/cdrom; sudo sh /media/cdrom/VBoxLinuxAdditions.run; sudo umount /media/cdrom; sudo shutdown -h now"
  echo -n "Waiting for machine to shut off "
  while VBoxManage list runningvms | grep "${BOX}" >/dev/null; do
    sleep 20
    echo -n "."
  done
  echo ""

  VBoxManage modifyvm "${BOX}" --natpf1 delete "guestssh"

  # Detach guest additions iso
  echo "Detach guest additions ..."
  VBoxManage storageattach "${BOX}" \
    --storagectl "IDE Controller" \
    --port 1 \
    --device 0 \
    --type dvddrive \
    --medium emptydrive
fi

echo "Building Vagrant Box ..."
vagrant package --base "${BOX}"

# references:
# http://blog.ericwhite.ca/articles/2009/11/unattended-debian-lenny-install/
# http://cdimage.ubuntu.com/releases/precise/beta-2/
# http://www.imdb.com/name/nm1483369/
# http://vagrantup.com/docs/base_boxes.html

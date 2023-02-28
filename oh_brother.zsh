#!/usr/bin/env zsh
version=0.1
set -Eeuo pipefail  # exit on first error

#correctly set $0
0="${${ZERO:-${0:#ZSH_ARGZERO}}:-${(%):-%N}}"

zparseopts -D -E -- \
    -version=show_version \
    -debug=debug \
    -clean=clean \
    h=show_usage -help=show_usage \

# enable debug mode
[[ "$debug" ]] && set -x

# show version number
[[ -n "$show_version" ]] && echo $version && exit 0

# show usage
if [[ -n "$show_usage" ]] {
    cat <<-EOF
Usage: ${0:t} [options]

-h --help   this message
--version   script version
EOF
    exit 0
}


model=${1:-HL-4570CDW}
model_clean=${${model/-/}:l}

model_info=$(curl -L http://www.brother.com/pub/bsc/linux/infs/${model_clean:u})

PRN_CUP_DEB=$(echo $model_info | awk -F= '/PRN_CUP_DEB/ {print $2}')
PRN_LPD_DEB=$(echo $model_info | awk -F= '/PRN_LPD_DEB/ {print $2}')
version=${${PRN_CUP_DEB/*cdwcupswrapper-/}%.i386.deb}

build_root="$(pwd)/build_${model_clean}"
[[ "$clean" && -d "$build_root" ]] && rm -rf "$build_root"

mkdir -p $build_root
cd $build_root

dl_base="https://www.brother.com/pub/bsc/linux/dlf/"

cups_src_tgz_url="${dl_base}/${model_clean}cupswrapper-src-${version}.tar.gz"
cups_src_tgz=${cups_src_tgz_url:t}
cups_src=${cups_src_tgz%.tar.gz}
[[ -e $cups_src_tgz ]] || curl -LO $cups_src_tgz_url
[[ -d $cups_src ]] && rm -rf $cups_src

lpr_deb_url="$dl_base/$PRN_LPD_DEB"
lpr_i386_deb=${lpr_deb_url:t}
lpr_armf_deb=${lpr_i386_deb%.i386.deb}.armf.deb
lpr_armf_extracted=${lpr_i386_deb%.i386.deb}.armf.extracted
[[ -e $lpr_i386_deb ]] || curl -LO $lpr_deb_url
[[ -d $lpr_armf_extracted ]] && rm -rf $lpr_armf_extracted

cupswraper_url="$dl_base/$PRN_CUP_DEB"
cupswraper_i386_deb=${cupswraper_url:t}
cupswraper_armf_deb=${cupswraper_i386_deb%.i386.deb}.armf.deb
cupswraper_armf_extracted=${cupswraper_i386_deb%.i386.deb}.armf.extracted
[[ -e $cupswraper_i386_deb ]] || curl -LO $cupswraper_url
[[ -d $cupswraper_armf_extracted ]] && rm -rf $cupswraper_armf_extracted


# ---------------------------------------------------------------------------- #
#                             Repackage LPR drivers                            #
# ---------------------------------------------------------------------------- #
# Get the original i386 LPR driver, unpack the files and the control information
dpkg -x $lpr_i386_deb $lpr_armf_extracted
dpkg-deb -e $lpr_i386_deb $lpr_armf_extracted/DEBIAN
sed -i 's/Architecture: i386/Architecture: armhf/' $lpr_armf_extracted/DEBIAN/control
echo true > $lpr_armf_extracted/usr/local/Brother/Printer/$model_clean/inf/braddprinter

# Grab the Brother ARM drivers from a generic armhf archive they provide and copy the ARM code into the unpacked folders. Note that HL2270 does not use brprintconflsr3.
generic_deb=brgenprintml2pdrv-4.0.0-1.armhf.deb
[[ -e $generic_deb ]] || curl -LO http://download.brother.com/welcome/dlf103361/$generic_deb
dpkg -x $generic_deb $generic_deb.extracted
cp $generic_deb.extracted/opt/brother/Printers/BrGenPrintML2/lpd/armv7l/rawtobr3 $lpr_armf_extracted/usr/local/Brother/Printer/$model_clean/lpd

# Now repackage it
cd $lpr_armf_extracted
find . -type f ! -regex '.*.hg.*' ! -regex '.*?debian-binary.*' ! -regex '.*?DEBIAN.*' -printf '%P ' | xargs md5sum > DEBIAN/md5sums
cd $build_root

chmod 755 $lpr_armf_extracted/DEBIAN/p* $lpr_armf_extracted/usr/local/Brother/Printer/$model_clean/inf/* $lpr_armf_extracted/usr/local/Brother/Printer/$model_clean/lpd/*
dpkg-deb -b $lpr_armf_extracted $lpr_armf_deb


# ---------------------------------------------------------------------------- #
#                            Repackage CUPS wrapper                            #
# ---------------------------------------------------------------------------- #
cd $build_root

# Grab and extract the brcupsconfig4 sources
tar zxvf $cups_src_tgz
cd $cups_src

# Compile brcupsconfig4
gcc brcupsconfig/brcupsconfig.c -o brcupsconfig4
cd $build_root
# If you are running these steps on the arm64 platform do cross complilation by first getting arm-linux-gnueabihf-gcc-9 via sudo apt install gcc-9-arm-linux-gnueabihf and then running arm-linux-gnueabihf-gcc-9 brcupsconfig3/brcupsconfig.c -o brcupsconfig4

# Grab the original i386 CUPS wrapper and unpack it
dpkg -x $cupswraper_i386_deb $cupswraper_armf_extracted
dpkg-deb -e $cupswraper_i386_deb $cupswraper_armf_extracted/DEBIAN
sed -i 's/Architecture: i386/Architecture: armhf/' $cupswraper_armf_extracted/DEBIAN/control

# Copy the compiled code into the unpacked folder
cp $cups_src/brcupsconfig4 $cupswraper_armf_extracted/usr/local/Brother/Printer/$model_clean/cupswrapper

# Repack it
cd $cupswraper_armf_extracted
find . -type f ! -regex '.*.hg.*' ! -regex '.*?debian-binary.*' ! -regex '.*?DEBIAN.*' -printf '%P ' | xargs md5sum > DEBIAN/md5sums
cd $build_root

chmod 755 $cupswraper_armf_extracted/DEBIAN/p* $cupswraper_armf_extracted/usr/local/Brother/Printer/$model_clean/cupswrapper/*
dpkg-deb -b $cupswraper_armf_extracted $cupswraper_armf_deb


# ---------------------------------------------------------------------------- #
#                                  Installing                                  #
# ---------------------------------------------------------------------------- #

# Note: if you are using RPi4 64 bit OS (AARCH64 aka ARM64) you need to install libc6:armhf. No need to do it on ARM32 aka AARCH32 aka armhf aka armv7l
# sudo dpkg --add-architecture armhf
# sudo apt update
# sudo apt install libc6:armhf

# Install prereqs and install the drivers
cd $build_root
sudo apt install --yes psutils cups ./$lpr_armf_deb ./$cupswraper_armf_deb
sudo systemctl restart cups
# You may need to install other runtime dependencies such as a2ps, glibc-32bit, ghostscript

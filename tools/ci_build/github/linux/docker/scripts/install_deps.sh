#!/bin/bash
set -e -x

SCRIPT_DIR="$( dirname "${BASH_SOURCE[0]}" )"
INSTALL_DEPS_TRAINING=false
INSTALL_DEPS_DISTRIBUTED_SETUP=false
CU_VER="11.8"

while getopts p:d:v:m parameter_Option
do case "${parameter_Option}"
in
p) PYTHON_VER=${OPTARG};;
d) DEVICE_TYPE=${OPTARG};;
v) CU_VER=${OPTARG};;
m) INSTALL_DEPS_DISTRIBUTED_SETUP=true;;
b) BUILD_TYPE=${OPTARG}
esac
done

echo "Python version=$PYTHON_VER"
echo "Build type=$BUILD_TYPE"

DEVICE_TYPE=${DEVICE_TYPE:=Normal}

#Download a file from internet
function GetFile {
  local uri=$1
  local path=$2
  local force=${3:-false}
  local download_retries=${4:-5}
  local retry_wait_time_seconds=${5:-30}

  if [[ -f $path ]]; then
    if [[ $force = false ]]; then
      echo "File '$path' already exists. Skipping download"
      return 0
    else
      rm -rf $path
    fi
  fi

  if [[ -f $uri ]]; then
    echo "'$uri' is a file path, copying file to '$path'"
    cp $uri $path
    return $?
  fi

  echo "Downloading $uri"
  # Use aria2c if available, otherwise use curl
  if command -v aria2c > /dev/null; then
    aria2c -q -d $(dirname $path) -o $(basename $path) "$uri"
  else
    curl "$uri" -sSL --retry $download_retries --retry-delay $retry_wait_time_seconds --create-dirs -o "$path" --fail
  fi

  return $?
}

if [[ "$PYTHON_VER" = "3.8" && -d "/opt/python/cp38-cp38"  ]]; then
   PYTHON_EXE="/opt/python/cp38-cp38/bin/python3.8"
elif [[ "$PYTHON_VER" = "3.9" && -d "/opt/python/cp39-cp39"  ]]; then
   PYTHON_EXE="/opt/python/cp39-cp39/bin/python3.9"
elif [[ "$PYTHON_VER" = "3.10" && -d "/opt/python/cp310-cp310"  ]]; then
   PYTHON_EXE="/opt/python/cp310-cp310/bin/python3.10"
elif [[ "$PYTHON_VER" = "3.11" && -d "/opt/python/cp311-cp311"  ]]; then
   PYTHON_EXE="/opt/python/cp311-cp311/bin/python3.11"
else
   PYTHON_EXE="/usr/bin/python${PYTHON_VER}"
fi

SYS_LONG_BIT=$(getconf LONG_BIT)
mkdir -p /tmp/src
GLIBC_VERSION=$(getconf GNU_LIBC_VERSION | cut -f 2 -d \.)

DISTRIBUTOR=$(lsb_release -i -s)

if [[ "$DISTRIBUTOR" = "CentOS" && $SYS_LONG_BIT = "64" ]]; then
  LIBDIR="lib64"
else
  LIBDIR="lib"
fi
if [[ $SYS_LONG_BIT = "64" && "$GLIBC_VERSION" -gt "9" ]]; then
  echo "Installing azcopy"
  mkdir -p /tmp/azcopy
  GetFile https://aka.ms/downloadazcopy-v10-linux /tmp/azcopy/azcopy.tar.gz
  tar --strip 1 -xf /tmp/azcopy/azcopy.tar.gz -C /tmp/azcopy
  cp /tmp/azcopy/azcopy /usr/bin
  echo "Installing cmake"
  GetFile https://github.com/Kitware/CMake/releases/download/v3.18.2/cmake-3.18.2-Linux-x86_64.tar.gz /tmp/src/cmake-3.18.2-Linux-x86_64.tar.gz
  tar -zxf /tmp/src/cmake-3.18.2-Linux-x86_64.tar.gz --strip=1 -C /usr

  echo "Installing Ninja"
  GetFile https://github.com/ninja-build/ninja/archive/v1.10.0.tar.gz /tmp/src/ninja-linux.tar.gz
  cd /tmp/src
  tar -zxf ninja-linux.tar.gz
  cd ninja-1.10.0
  cmake -Bbuild-cmake -H.
  cmake --build build-cmake
  mv ./build-cmake/ninja /usr/bin

  echo "Installing Node.js"
  GetFile https://nodejs.org/dist/v12.16.3/node-v12.16.3-linux-x64.tar.xz /tmp/src/node-v12.16.3-linux-x64.tar.xz
  tar -xf /tmp/src/node-v12.16.3-linux-x64.tar.xz --strip=1 -C /usr
else
  echo "Installing cmake"
  GetFile https://github.com/Kitware/CMake/releases/download/v3.18.2/cmake-3.18.2.tar.gz /tmp/src/cmake-3.18.2.tar.gz
  tar -xf /tmp/src/cmake-3.18.2.tar.gz -C /tmp/src
  pushd .
  cd /tmp/src/cmake-3.18.2
  ./bootstrap --prefix=/usr --parallel=$(getconf _NPROCESSORS_ONLN) --system-bzip2 --system-curl --system-zlib --system-expat
  make -j$(getconf _NPROCESSORS_ONLN)
  make install
  popd
fi

GetFile https://downloads.gradle-dn.com/distributions/gradle-6.3-bin.zip /tmp/src/gradle-6.3-bin.zip
cd /tmp/src
unzip gradle-6.3-bin.zip
mv /tmp/src/gradle-6.3 /usr/local/gradle

if ! [ -x "$(command -v protoc)" ]; then
  source ${0/%install_deps\.sh/install_protobuf\.sh}
fi

${PYTHON_EXE} -m pip install --upgrade pip

export ONNX_ML=1
export CMAKE_ARGS="-DONNX_GEN_PB_TYPE_STUBS=OFF -DONNX_WERROR=OFF"
if [ $BUILD_TYPE = "stable" ]; then
  ${PYTHON_EXE} -m pip install -r ${0/%install_deps.sh/training\/ortmodule\/stage1\/requirements_torch_cu${CU_VER}_stable.txt}
elif [ $BUILD_TYPE = "nightly" ]; then
  ${PYTHON_EXE} -m pip install -r ${0/%install_deps.sh/training\/ortmodule\/stage1\/requirements_torch_cu${CU_VER}_nightly.txt}
else
  echo "ERROR: Build type must be either nightly or stable. Unrecognized build type $BUILD_TYPE"
  exit 1
fi

# Due to a [bug on DeepSpeed](https://github.com/microsoft/DeepSpeed/issues/663), we install it separately through ortmodule/stage2/requirements.txt
${PYTHON_EXE} -m pip install -r ${0/%install_deps.sh/training\/ortmodule\/stage2\/requirements.txt}
if [[ $INSTALL_DEPS_DISTRIBUTED_SETUP = true ]]; then
  source ${0/%install_deps.sh/install_openmpi.sh}
fi

cd /
rm -rf /tmp/src
rm -rf /usr/include/google
rm -rf /usr/$LIBDIR/libproto*

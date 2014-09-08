#!/bin/bash

# Copyright 2014 Google Inc. All rights reserved.
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#    http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

set -o errexit
mkdir -p output/classes
mkdir -p output/test_classes
mkdir -p output/src
mkdir -p output/objs
mkdir -p output/native

PLATFORM=$(uname -s | tr 'A-Z' 'a-z')
ARCHIVE_CFLAGS=""
ARCHIVE_LDFLAGS=""

case ${PLATFORM} in
darwin)
  homebrew_header=$(ls -1 /usr/local/Cellar/libarchive/*/include/archive.h | head -n1)
  if [[ -e /opt/local/include/archive.h ]]; then
    # For use with Macports.
    ARCHIVE_CFLAGS="-I/opt/local/include"
    ARCHIVE_LDFLAGS="-L/opt/local/lib"
  elif [[ -e $homebrew_header ]]; then
    # For use with Homebrew.
    archive_dir=$(dirname $(dirname $homebrew_header))
    ARCHIVE_CFLAGS="-I${archive_dir}/include"
    ARCHIVE_LDFLAGS="-L${archive_dir}/lib"
  else
    echo "WARNING: Could not find libarchive installation, proceeding bravely."
  fi

  DYNAMIC_EXT="dylib"
  REALTIME_LDFLAGS=""
  MD5SUM="md5"
  JAVA_HOME=${JAVA_HOME:-$(/usr/libexec/java_home -v 1.7+)}
  ;;
linux)
  DYNAMIC_EXT="so"
  REALTIME_LDFLAGS="-lrt"
  MD5SUM="md5sum"
  # JAVA_HOME must point to a Java 7 installation.
  JAVA_HOME=${JAVA_HOME:-$(readlink -f $(which javac) | sed "s_/bin/javac__")}
  ;;
esac

# Compile .proto files using protoc
PROTO_FILES=(src/main/protobuf/*.proto)

# TODO: CC target architecture needs to match JAVA_HOME.

JAVAC="${JAVA_HOME}/bin/javac"
PROTOC=${PROTOC:-protoc}
CC=${CC:-g++}

for FILE in "${PROTO_FILES[@]}"; do
  echo "PROTOC ${FILE}"
  "${PROTOC}" \
      -Isrc/main/protobuf/ \
      --java_out=output/src \
      "${FILE}"
done

# Compile .java files (incl. generated ones) using javac
echo "JAVAC src/main/java/**/*.java"
CLASSPATH=third_party/guava/guava-16.0.1.jar:third_party/jsr305/jsr-305.jar:third_party/protobuf/protobuf-2.5.0.jar:third_party/joda-time/joda-time-2.3.jar
DIRS=$(echo src/{main/java,tools/{singlejar,xcode-common}})
find ${DIRS} -name "*.java" | xargs "${JAVAC}" -classpath ${CLASSPATH} -sourcepath ${DIRS// /:}:output/src -d output/classes

echo "UNZIP third_party/{guava,joda-time,jsr305,protobuf}/*.jar"
for f in $(echo ${CLASSPATH} | tr ':' ' ') ; do
  unzip -qn ${f} -d output/classes
done

# help files.
cp src/main/java/com/google/devtools/build/lib/blaze/commands/*.txt output/classes/com/google/devtools/build/lib/blaze/commands/

echo "JAR libblaze.jar"
echo "Main-Class: com.google.devtools.build.lib.bazel.BazelMain" > output/MANIFEST.MF
jar cmf output/MANIFEST.MF output/libblaze.jar -C output/classes com/ -C output/classes javax/ -C output/classes org/

function build_objc_tool() {
  CLASS=$1
  EXTRA_DIRS="$2"
  TOOL=$(echo ${CLASS} | tr '[:upper:]' '[:lower:]')

  mkdir -p output/${TOOL}_classes
  echo "JAVAC src/tools/${TOOL}/java/**/*.java"
  CLASSPATH=third_party/guava/guava-16.0.1.jar:third_party/protobuf/protobuf-2.5.0.jar:third_party/jsr305/jsr-305.jar
  DIRS=$(echo src/tools/{${TOOL},singlejar,xcode-common/java} src/main/java/com/google/devtools/common/options src/third_party/dd_plist/java src/third_party/buck/java ${EXTRA_DIRS})
  find ${DIRS} -name "*.java" | xargs "${JAVAC}" -classpath ${CLASSPATH} -sourcepath ${DIRS// /:}:output/src -d output/${TOOL}_classes

  echo "UNZIP deps for ${TOOL}"
  for f in $(echo ${CLASSPATH} | tr ':' ' ') ; do
    unzip -qn ${f} -d output/${TOOL}_classes
  done

  echo "JAR ${TOOL}_deploy.jar"
  mkdir -p output/${TOOL}
  echo "Main-Class: com.google.devtools.build.xcode.${TOOL}.${CLASS}" > output/${TOOL}/MANIFEST.MF
  jar cmf output/${TOOL}/MANIFEST.MF output/${TOOL}_deploy.jar -C output/${TOOL}_classes com/
}

OBJC_TOOLS="ActoolZip MomcZip PlMerge XcodeGen"
for tool in ${OBJC_TOOLS} ; do
  build_objc_tool ${tool}
done
build_objc_tool BundleMerge src/tools/plmerge/java
ALL_OBJC_TOOLS="${OBJC_TOOLS} BundleMerge"

echo "JAVAC src/test/java/**/*.java"
find src/test/java -name "*.java" | xargs "${JAVAC}" -classpath ${CLASSPATH}:third_party/junit/junit-4.11.jar:third_party/truth/truth-0.23.jar:third_party/guava/guava-testlib.jar:output/classes -d output/test_classes

# Compile client .cc files.
BLAZE_CC_FILES=(
src/main/cpp/blaze_startup_options.cc
src/main/cpp/blaze_startup_options_common.cc
src/main/cpp/blaze_util.cc
src/main/cpp/blaze_util_${PLATFORM}.cc
src/main/cpp/blaze.cc
src/main/cpp/option_processor.cc
src/main/cpp/util/port.cc
src/main/cpp/util/strings.cc
src/main/cpp/util/file.cc
src/main/cpp/util/md5.cc
src/main/cpp/util/numbers.cc
)

for FILE in "${BLAZE_CC_FILES[@]}"; do
  if [[ ! "${FILE}" =~ ^-.*$ ]]; then
    echo "CC ${FILE}"
    OUT=$(basename "${FILE}").o
    "${CC}" \
        -I src/main/cpp/ \
        -I /usr/include/ \
        ${ARCHIVE_CFLAGS} \
        -std=c++0x \
        -c \
        -DBLAZE_JAVA_CPU=\"k8\" \
        -DBLAZE_OPENSOURCE=1 \
        -o "output/objs/${OUT}" \
        "${FILE}"
  fi
done

# Link client
echo "LD client"
"${CC}" -o output/client output/objs/*.o ${ARCHIVE_LDFLAGS} -larchive -l stdc++ ${REALTIME_LDFLAGS}

# Compile native code .cc files.
NATIVE_CC_FILES=(
src/main/native/localsocket.cc
src/main/native/process.cc
src/main/native/unix_jni.cc
src/main/native/unix_jni_${PLATFORM}.cc
src/main/cpp/util/md5.cc
)

for FILE in "${NATIVE_CC_FILES[@]}"; do
  echo "CC ${FILE}"
  OUT=$(basename "${FILE}").o
  "${CC}" \
      -I src/main/cpp/ \
      -I src/main/native/ \
      -I "${JAVA_HOME}/include/" \
      -I "${JAVA_HOME}/include/${PLATFORM}" \
      -std=c++0x \
      -fPIC \
      -c \
      -DBLAZE_JAVA_CPU=\"k8\" \
      -DBLAZE_OPENSOURCE=1 \
      -o "output/native/${OUT}" \
      "${FILE}"
done

echo "LD libunix.${DYNAMIC_EXT}"
"${CC}" -o output/libunix.${DYNAMIC_EXT} -shared output/native/*.o -l stdc++

echo "CC build-runfiles"
# Clang on Linux requires libstdc++
"${CC}" -o output/build-runfiles -std=c++0x -l stdc++ src/main/tools/build-runfiles.cc

echo "CC process-wrapper"
"${CC}" -o output/process-wrapper src/main/tools/process-wrapper.c

cp src/main/tools/build_interface_so output/build_interface_so

touch output/alarm
chmod 755 output/alarm

touch output/client_info
chmod 755 output/client_info

TO_ZIP="libblaze.jar libunix.${DYNAMIC_EXT} build-runfiles process-wrapper alarm client_info build_interface_so"
(cd output/ ; cat client ${TO_ZIP} | ${MD5SUM} | awk '{ print $1; }' > install_base_key)
(cd output/ ; zip package.zip ${TO_ZIP} install_base_key)
cat output/client output/package.zip > output/bazel
zip -qA output/bazel
chmod 755 output/bazel

for t in ${ALL_OBJC_TOOLS}; do
  tool=$(echo ${t} | tr '[:upper:]' '[:lower:]')
  cp output/${tool}_deploy.jar example_workspace/tools/objc/
done

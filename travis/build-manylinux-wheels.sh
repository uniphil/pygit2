#!/usr/bin/env bash

set -x
set -e

LIBGIT2_VERSION="$1"

set -euo pipefail

if [ -z "$LIBGIT2_VERSION" ]
then
    >&2 echo "Please pass libgit2 version as a second argument of this script ($0)"
    exit 1
fi

PYTHONS="cp36-cp36m cp37-cp37m cp38-cp38 cp39-cp39"


# Avoid creation of __pycache__/*.py[c|o]
export PYTHONDONTWRITEBYTECODE=1

SRC_DIR=/io
BUILD_DIR=`mktemp -d "/tmp/pygit2-manylinux2014-build.XXXXXXXXXX"`
TESTS_DIR="${BUILD_DIR}/test"
STATIC_DEPS_PREFIX="${BUILD_DIR}/static-deps"
LIBGIT2_CLONE_DIR="${BUILD_DIR}/libgit2"
LIBGIT2_BUILD_DIR="${LIBGIT2_CLONE_DIR}/build"
export LIBGIT2="${STATIC_DEPS_PREFIX}"

ZLIB_VERSION=1.2.11
ZLIB_DOWNLOAD_DIR="${BUILD_DIR}/zlib-${ZLIB_VERSION}"

LIBSSH2_VERSION=1.9.0
LIBSSH2_CLONE_DIR="${BUILD_DIR}/libssh2"
LIBSSH2_BUILD_DIR="${LIBSSH2_CLONE_DIR}/build"

ORIG_WHEEL_DIR="${BUILD_DIR}/original-wheelhouse"
WHEEL_DEP_DIR="${BUILD_DIR}/deps-wheelhouse"
WHEELHOUSE_DIR="${SRC_DIR}/dist"

function cleanup_garbage() {
    # clear python cache
    >&2 echo
    >&2 echo
    >&2 echo === Clean up python bytecode cache files ===
    >&2 echo
    find "${SRC_DIR}" -type f -name *.pyc -o -name *.pyo -print0 | xargs -0 rm -fv
    find "${SRC_DIR}" -type d -name __pycache__ -print0 | xargs -0 rm -rfv

    # clear python cache
    >&2 echo
    >&2 echo
    >&2 echo === Clean up files untracked by Git ===
    >&2 echo
    git --git-dir=${SRC_DIR}/.git --work-tree=${SRC_DIR} clean -fxd --exclude dist/
}

cleanup_garbage

mkdir -p "$WHEELHOUSE_DIR"

export PYCA_OPENSSL_PATH=/opt/pyca/cryptography/openssl
export OPENSSL_PATH=/opt/openssl

export CFLAGS="-fPIC"
export LD_LIBRARY_PATH="${STATIC_DEPS_PREFIX}/lib64:${STATIC_DEPS_PREFIX}/lib:$LD_LIBRARY_PATH"
export PKG_CONFIG_PATH="${STATIC_DEPS_PREFIX}/lib64/pkgconfig:${STATIC_DEPS_PREFIX}/lib/pkgconfig:${OPENSSL_PATH}/lib/pkgconfig:${PYCA_OPENSSL_PATH}/lib/pkgconfig"

ARCH=`uname -m`


>&2 echo
>&2 echo
>&2 echo ========================
>&2 echo Installing system deps...
>&2 echo ========================
>&2 echo
yum -y install git libffi-devel cmake3

>&2 echo
>&2 echo
>&2 echo =======================
>&2 echo Upgrading auditwheel...
>&2 echo =======================
>&2 echo
/opt/python/cp36-cp36m/bin/python -m pip install --no-compile -U auditwheel

>&2 echo
>&2 echo
>&2 echo ============================================
>&2 echo downloading source of zlib v${ZLIB_VERSION}:
>&2 echo ============================================
>&2 echo
curl https://www.zlib.net/zlib-${ZLIB_VERSION}.tar.gz | tar xzvC "${BUILD_DIR}" -f -

pushd "${ZLIB_DOWNLOAD_DIR}"
./configure --static --prefix="${STATIC_DEPS_PREFIX}" && \
    make -j9 libz.a && \
    make install
popd

>&2 echo
>&2 echo
>&2 echo ==================================================
>&2 echo downloading source of libssh2 v${LIBSSH2_VERSION}:
>&2 echo ==================================================
>&2 echo
git clone \
    --depth=1 \
    -b "libssh2-${LIBSSH2_VERSION}" \
    https://github.com/libssh2/libssh2.git \
    "${LIBSSH2_CLONE_DIR}"

mkdir -p "${LIBSSH2_BUILD_DIR}"
pushd "${LIBSSH2_BUILD_DIR}"
cmake3 "${LIBSSH2_CLONE_DIR}" \
    -DCMAKE_INSTALL_PREFIX="${STATIC_DEPS_PREFIX}" \
    -DBUILD_SHARED_LIBS=OFF \
    -DBUILD_EXAMPLES=OFF \
    -DBUILD_TESTING=OFF \
    -DCRYPTO_BACKEND=OpenSSL \
    -DENABLE_ZLIB_COMPRESSION=ON
cmake3 --build "${LIBSSH2_BUILD_DIR}" --target install
popd

>&2 echo
>&2 echo
>&2 echo ==================================================
>&2 echo downloading source of libgit2 v${LIBGIT2_VERSION}:
>&2 echo ==================================================
>&2 echo
git clone \
    --depth=1 \
    -b "maint/v${LIBGIT2_VERSION}" \
    https://github.com/libgit2/libgit2.git \
    "${LIBGIT2_CLONE_DIR}"

>&2 echo
>&2 echo
>&2 echo ===================
>&2 echo Building libgit2...
>&2 echo ===================
>&2 echo
mkdir -p "${LIBGIT2_BUILD_DIR}"
pushd "${LIBGIT2_BUILD_DIR}"
# Ref https://libgit2.org/docs/guides/build-and-link/
cmake3 "${LIBGIT2_CLONE_DIR}" \
    -DCMAKE_INSTALL_PREFIX="${STATIC_DEPS_PREFIX}" \
    -DCMAKE_BUILD_TYPE=Release \
    -DBUILD_CLAR=OFF \
    -DTHREADSAFE=ON
cmake3 --build "${LIBGIT2_BUILD_DIR}" --target install
popd

>&2 echo
>&2 echo
>&2 echo ================
>&2 echo Building wheels:
>&2 echo ================
>&2 echo
for PY in $PYTHONS; do
    PIP_BIN="/opt/python/${PY}/bin/pip"
    cleanup_garbage
    # XXX pygit2 is built here
    ${PIP_BIN} wheel "${SRC_DIR}" -w "${ORIG_WHEEL_DIR}"
done

>&2 echo
>&2 echo
>&2 echo ================
>&2 echo Reparing wheels:
>&2 echo ================
>&2 echo
# Bundle external shared libraries into the wheels
for PY in $PYTHONS; do
    for whl in ${ORIG_WHEEL_DIR}/pygit2-*-${PY}-linux_${ARCH}.whl; do
        cleanup_garbage
        >&2 echo Reparing "${whl}"...
        auditwheel repair "${whl}" -w ${WHEELHOUSE_DIR}
    done
done

# Download deps
>&2 echo
>&2 echo
>&2 echo =========================
>&2 echo Downloading dependencies:
>&2 echo =========================
>&2 echo
for PY in $PYTHONS; do
    PIP_BIN="/opt/python/${PY}/bin/pip"
    WHEEL_FILE=`ls ${WHEELHOUSE_DIR}/pygit2-*-${PY}-manylinux2014_${ARCH}.whl`
    cleanup_garbage
    >&2 echo Downloading ${WHEEL_FILE} deps using ${PIP_BIN}...
    ${PIP_BIN} download -d "${WHEEL_DEP_DIR}" "${WHEEL_FILE}"
done

# Install packages
>&2 echo
>&2 echo
>&2 echo ============================
>&2 echo Testing wheels installation:
>&2 echo ============================
>&2 echo
for PY in $PYTHONS; do
    PIP_BIN="/opt/python/${PY}/bin/pip"
    cleanup_garbage
    >&2 echo Using ${PIP_BIN}...
    ${PIP_BIN} install --no-compile "pygit2" --no-index -f ${WHEEL_DEP_DIR} #&
done
wait

# Running analysis
>&2 echo
>&2 echo
>&2 echo =============
>&2 echo SMOKE TESTING
>&2 echo =============
>&2 echo
for PY in $PYTHONS; do
    PY_BIN="/opt/python/${PY}/bin/python"
    cleanup_garbage
    $PY_BIN -B -V
    $PY_BIN -B -c '
import pygit2
print("libgit2 version: %s" % pygit2.LIBGIT2_VERSION)
print("pygit2 supports threads: %s" % str(bool(pygit2.features & pygit2.GIT_FEATURE_THREADS)))
print("pygit2 supports HTTPS: %s" % str(bool(pygit2.features & pygit2.GIT_FEATURE_HTTPS)))
print("pygit2 supports SSH: %s" % str(bool(pygit2.features & pygit2.GIT_FEATURE_SSH)))
print("")
    '
done

cleanup_garbage
>&2 echo
>&2 echo ==============
>&2 echo WHEEL ANALYSIS
>&2 echo ==============
>&2 echo
for PY in $PYTHONS; do
    WHEEL_BIN="/opt/python/${PY}/bin/wheel"
    WHEEL_FILE=`ls ${WHEELHOUSE_DIR}/pygit2-*-${PY}-manylinux2014_${ARCH}.whl`
    >&2 echo Analysing ${WHEEL_FILE}...
    auditwheel show "${WHEEL_FILE}"
    ${WHEEL_BIN} unpack -d "${BUILD_DIR}/${PY}-pygit2" "${WHEEL_FILE}"
done

>&2 echo
>&2 echo
>&2 echo ==================================
>&2 echo Running test suite against wheels:
>&2 echo ==================================
>&2 echo
cp -v ${SRC_DIR}/pytest.ini ${BUILD_DIR}/
cp -vr ${SRC_DIR}/test ${TESTS_DIR}
pushd "${BUILD_DIR}"
for PY in $PYTHONS; do
    PY_BIN="/opt/python/${PY}/bin/python"
    cleanup_garbage
    $PY_BIN -B -m pip install --no-compile pytest
    $PY_BIN -B -m pytest "${TESTS_DIR}" &
done
wait
popd

>&2 echo
>&2 echo
>&2 echo ==================
>&2 echo SELF-TEST COMPLETE
>&2 echo ==================
>&2 echo

cleanup_garbage

chown -R --reference="${SRC_DIR}/.travis.yml" "${SRC_DIR}"
>&2 echo Final OS-specific wheels for pygit2:
ls -l ${WHEELHOUSE_DIR}

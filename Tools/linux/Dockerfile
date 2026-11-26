# From the Serein checkout, after Tools/apply-vendor-patches.sh:
# docker build -f Tools/linux/Dockerfile -t serein-toolchain vendor/libsignal
FROM rust:1.98.1-bookworm AS libsignal
RUN apt-get update && apt-get install -y --no-install-recommends clang libclang-dev cmake protobuf-compiler libprotobuf-dev \
    && rm -rf /var/lib/apt/lists/*
WORKDIR /build/libsignal
COPY Cargo.toml Cargo.lock rust-toolchain ./
COPY rust/ rust/
COPY bin/ bin/
COPY swift/build_ffi.sh swift/
RUN export CARGO_BUILD_TARGET="$(rustc -vV | sed -n 's/^host: //p')" CARGO_BUILD_JOBS=4 \
    && swift/build_ffi.sh --release \
    && cp "target/$CARGO_BUILD_TARGET/release/libsignal_ffi.a" /libsignal_ffi.a

FROM swift:6.2-noble AS sqlcipher
RUN apt-get update && apt-get install -y --no-install-recommends make tcl libssl-dev \
    && rm -rf /var/lib/apt/lists/*

# Match the 4.20.0 library used by the macOS build.
WORKDIR /build
RUN git init && git fetch --depth=1 https://github.com/sqlcipher/sqlcipher.git 355d4db92d3404e71faa8088d071a71d767807f4 \
    && git checkout --detach FETCH_HEAD
RUN CC=clang CC_FOR_BUILD=clang ./configure --with-tempstore=yes --enable-fts5 && make -j4 sqlite3.c \
    && mkdir -p /out/include/sqlcipher /out/lib \
    && clang -O2 -fPIC -shared -Wl,-soname,libsqlcipher.so.4 -Wl,-Bsymbolic \
        -DSQLITE_HAS_CODEC -DSQLITE_TEMP_STORE=2 -DSQLITE_THREADSAFE=1 \
        -DSQLITE_EXTRA_INIT=sqlcipher_extra_init -DSQLITE_EXTRA_SHUTDOWN=sqlcipher_extra_shutdown \
        -DSQLITE_ENABLE_FTS5 -DSQLITE_ENABLE_COLUMN_METADATA -DSQLITE_ENABLE_SNAPSHOT \
        sqlite3.c -o /out/lib/libsqlcipher.so.4 -lcrypto -lm -lpthread -ldl \
    && ln -s libsqlcipher.so.4 /out/lib/libsqlcipher.so \
    && cp sqlite3.h sqlite3ext.h /out/include/sqlcipher/

# Serein uses lifetime features and type checking from the Swift 6.4 toolchain.
FROM swift:6.4-noble AS toolchain
RUN apt-get update && apt-get install -y --no-install-recommends qt6-base-dev pkg-config fonts-dejavu-core libasound2-dev libsoundtouch-dev libsecret-1-dev libsoup-3.0-dev glib-networking \
    && rm -rf /var/lib/apt/lists/*
COPY --from=sqlcipher /out/ /usr/local/
COPY --from=libsignal /libsignal_ffi.a /usr/local/lib/
RUN ldconfig

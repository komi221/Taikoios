#!/bin/bash
# iOS는 ogg(Vorbis)를 기본 재생하지 못해서 public domain 디코더 stb_vorbis를 사용합니다.
set -e
mkdir -p Sources/Vendor
curl -fL -o Sources/Vendor/stb_vorbis.c https://raw.githubusercontent.com/nothings/stb/master/stb_vorbis.c
echo "ok: Sources/Vendor/stb_vorbis.c"

#ifndef Bridging_Header_h
#define Bridging_Header_h
// stb_vorbis.c (scripts/fetch_deps.sh 가 받아옴)
int stb_vorbis_decode_memory(const unsigned char *mem, int len, int *channels, int *sample_rate, short **output);
#endif

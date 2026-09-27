NVCC    ?= nvcc

# Which GPU architecture to build for.  "native" targets the GPU in this machine
# and needs CUDA 11.5 or newer; it requires a GPU to be present at build time.
#
#   make                  # this machine's GPU
#   make ARCH=sm_89       # one specific architecture (RTX 40xx here)
#   make ARCH=all-major   # every major architecture the toolkit knows, for a
#                         # portable binary or a build host without a GPU
ARCH    ?= native

CFLAGS   = -O3 -arch=$(ARCH) -Xcompiler "-O3" --ptxas-options=-v -I.

TARGET   = onion-gpu
SRCS     = main.cu
HDRS     = sha512.cuh sha3_256.cuh fe25519.cuh ge25519.cuh

all: $(TARGET)

$(TARGET): $(SRCS) $(HDRS)
	$(NVCC) $(CFLAGS) -o $@ $(SRCS)

clean:
	rm -f $(TARGET)

.PHONY: all clean

Pre-built binaries. Both statically link the CUDA runtime, so **you do not need the
CUDA toolkit** — only an NVIDIA driver.

| Download | For |
|----------|-----|
| `onion-gpu-linux-x86_64.tar.gz` | any x86-64 Linux with glibc 2.29+ (Ubuntu 20.04+, Debian 11+, RHEL 9+) |
| `onion-gpu-windows-x86_64.zip` | Windows 10/11 x64 |

Both contain GPU code for `sm_50, 60, 70, 80, 90, 100, 120` — every major
architecture from Maxwell (GTX 900) through Blackwell (RTX 50xx) — plus PTX so future
GPUs work by JIT. The Linux binary links only `libc.so.6`; nothing else is needed.

### Linux

```bash
tar xzf onion-gpu-linux-x86_64.tar.gz
cd onion-gpu-linux-x86_64
./onion-gpu -n 1 -o keys vanity
python3 verify.py keys
```

### Windows

Unzip and run from PowerShell or cmd:

```
onion-gpu.exe -n 1 -o keys vanity
```

### Verify your download

```bash
sha256sum -c SHA256SUMS.txt
```

### What has actually been tested

The **Linux** binary is run and verified on an RTX 5060 before release: the built-in
self-tests pass and generated keys are checked with `verify.py`.

The **Windows** build is compile-verified only. GitHub's runners have no NVIDIA GPU,
so no automated test can execute a kernel, and the author has no Windows machine to
test on. The Windows-specific code paths are entropy (`BCryptGenRandom`), file
creation and memory locking. If something misbehaves on Windows, please open an
issue — and see SECURITY.md for one real limitation: Windows builds cannot apply
POSIX `0600` permissions to the secret key file.

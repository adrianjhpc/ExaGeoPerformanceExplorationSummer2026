# NEXTGenIO Benchmarks README (September 2026)

## Benchmark results

Detailed results for each system can be found in [BENCHMARKS](./BENCHMARKS.md).

The raw benchmark data can be found under `data/`.

## DistributedStream (DS)

<https://github.com/adrianjhpc/DistributedStream>

### Building DistributedStream with oneAPI + Intel MPI

* You will need to build Mini-XML version 3.3.1
 (<https://github.com/michaelrsweet/mxml/releases/tag/v3.3.1>) as it is not
 installed on the system. I installed my build at `~/mxml` and the script will
 assume you've done the same. You can override this by setting `MXML_LIB_PATH`
 to point to wherever you install it.
* Mini-XML build guide:
 <https://github.com/michaelrsweet/mxml#building-mini-xml>
* DistributedStream build guide:
 <https://github.com/adrianjhpc/DistributedStream#building>
* Load the Intel OneAPI compiler:

```bash
module load compiler mpi
```

* Edit line 10 of the `Makefile` (the `CC = mpiicc` line) to be:

 ```bash
 CC = mpiicx
 ```

* Then run `make`
* When running DistributedStream, assuming you installed Mini-XML at
 `~/mxml`, you need to add its shared library path to the dynamic linker's
 search path, e.g.:

 ```bash
 LD_LIBRARY_PATH="$HOME/mxml/lib:$LD_LIBRARY_PATH" \
     ./distributed_streams 5000000 30
 ```

 This is handled in the script by setting `MXML_LIB_PATH`.

### Notes on DistributedStream

* You can compile and run `get_fp_and_tick_info.c` to get the size of
 floating point data types and clock tick granularity of the system.
* `sizeof(double)` is 8 bytes and clock tick granularity is <= 1μs on
 NEXTGenIO compute nodes.

* L3 cache sizes on each compute node type as reported by `lscpu`:

 | Node type | L3 cache size (bytes) |
 |-----------|-----------------------|
 | normal    | 37486592              |
 | amd       | 1677216               |
 | icx       | 44040192              |
 | gnr       | 1056964608            |

* I arbitrarily chose to use 30 repeats of the benchmark
* DistributedStream is not compatible with mxml v4 or later
* DistributedStream was built from git commit `c6534cc`

## High Performance Conjugate Gradient (HPCG)

### Building and running the Intel optimised HPCG benchmark with oneAPI + Intel MPI

[Intel® Optimized High Performance Conjugate Gradient Benchmark](https://www.intel.com/content/www/us/en/docs/onemkl/developer-guide-linux/2026-0/intel-opt-high-perf-conjugate-gradient-benchmark.html)  
[Getting Started with Intel® CPU Optimized HPCG](https://www.intel.com/content/www/us/en/docs/onemkl/developer-guide-linux/2026-0/getting-started-with-intel-cpu-optimized-hpcg.html)

* Instead of the HPCG reference implementation, version 2023.0.0 of the Intel
 optimised HPCG benchmark was used, as it is the newest available version
 installed.
 It is available at:

 ```bash
 /lustre/home/software/oneapi/mkl/2023.0.0/benchmarks/hpcg/
 ```

* The Intel provided binaries do not produce any output (I'm not sure why).
 Instead, you will need to build and run two versions of the benchmark under
 your home directory: The regular and ILP64 build.

* For this guide, the regular build tree will be located at
`~/benchmarks/intel_hpcg` and the ILP64 build tree at
`~/benchmarks/intel_hpcg_ilp64`

* First, ensure that all necessary build tools are loaded

```bash
module load packages-nextgenio packages-oneapi compiler/2023.0.0 mpi/2021.15
```

* Run configure for Intel MPI, AVX-512 build

```bash
mkdir -p ~/benchmarks/intel_hpcg
cd ~/benchmarks/intel_hpcg
/lustre/home/software/oneapi/mkl/2023.0.0/benchmarks/hpcg/configure IMPI_IOMP_SKX
```

* Copy the missing setup file

```bash
cp /lustre/home/software/oneapi/mkl/2023.0.0/benchmarks/hpcg/setup/Make.IMPI_IOMP_SKX setup/
```

* Edit the Makefile to point to the existing MKL via an absolute path

```bash
sed -i 's|MKLROOT=\.\./\.\.|MKLROOT=/lustre/home/software/oneapi/mkl/2023.0.0|' \
   setup/Make.IMPI_IOMP_SKX
```

* Finally, run `make`

* To build the ILP64 version, you can repeat the process above, however step
 two and the final `make` invocation are different:
 New step 2:

 ```bash
 mkdir -p ~/benchmarks/intel_hpcg_ilp64
 cd ~/benchmarks/intel_hpcg_ilp64
 /lustre/home/software/oneapi/mkl/2023.0.0/benchmarks/hpcg/configure IMPI_IOMP_SKX
 ```

And replace the final `make` with:

```bash
make HPCG_ILP64=yes
```

### Building and running the AMD optimised HPCG benchmark with AOCC + Open MPI

<https://www.amd.com/en/developer/zen-software-studio/applications/spack/hpcg-benchmark.html>

* ssh to the AMD node from the login node:  

 ```bash
 ssh nextgenio-amd01
 ```

* Install spack by following the guide at
 <https://spack-tutorial.readthedocs.io/en/latest/tutorial_basics.html>
* The default GCC and make are too old, so load more recent supported versions:

 ```bash
 module load gnu/11.2.0 gmake/4.4 binutils/2.40 compiler/2023.0.0
 ```

* Ensure spack can detect GCC:  

 ```bash
 spack compiler find && spack compiler list
 ```  

 You should see an entry similar to the following:  

 ```text
 -- gcc centos7-x86_64 -------------------------------------------
 [e]  gcc@4.8.5  [e]  gcc@11.2.0
 ```

* Make sure `gcc@11.2.0` is detected!
* CentOS 7 ships with Linux kernel 3.10 and glibc 2.17, which is older than
 AOCC's minimum requirement of 2.28. So we will need to compile glibc 2.28
 manually:

 ```bash
 cd $HOME
 wget https://ftp.gnu.org/gnu/glibc/glibc-2.28.tar.bz2
 p="$HOME/glibc-2.28" && mkdir -p "$p/src" "$p/build" "$p/install"
 tar xf glibc-2.28.tar.bz2 -C "$p/src"
 
 cd "$p/build"
 "$p/src/glibc-2.28/configure" \
     --prefix="$p/install" \
     --with-headers="/usr/include" \
     --disable-werror \
     --enable-kernel=3.10.0
 
 make --jobserver-style=pipe -j$(nproc)
 make install
 unset p
 ```

* The version of `file` spack attempts to build uses the `statx` syscall,
which is not defined in CentOS 7's glibc. The pre-installed version is
fine for compiling AOCC though. Register `file` as external so spack doesn't
try to build it. Run

```bash
spack config edit packages
```

and add the following entry under `packages:`

```yaml
  file:
    externals:
    - spec: file@5.11
      prefix: /usr
    buildable: false
```

* Install AOCC:

 ```bash
 spack install --dirty aocc +license-agreed %gcc@11.2.0
 ```

* Install patchelf. Make sure you use version 0.17.2 or newer.  

```bash
 spack install --dirty patchelf@0.17.2: %gcc@11.2.0
 spack load patchelf
```

* Run the

 ```bash
 ./patch_aocc.sh
 ```

  script to patch the AOCC binaries to use the newly
  compiled glibc. If you haven't changed any paths it should be fine with
  defaults. Please note this script is highly non-portable and will probably
  only work on `nextgenio-amd*` nodes specifically.

* spack's automatic detection of AOCC is buggy, so you will need to register
 it manually. First locate AOCC and copy this path somewhere you can use later:

 ```bash
 AOCC_LOC=$(spack location -i aocc@5.2.0) && echo "$AOCC_LOC"
 ```

 For a user named `user123` with `aocc@5.2.0` an example location may be:

 ```bash
 /lustre/home/<group>/<group>/user123/spack/opt/spack/linux-zen2/aocc-5.2.0-4dofy7jds5fkstl7dij4mjsjhgwobxbo
 ```

* Edit compilers with:

 ```bash
 spack config edit compilers
 ```

* Add an entry for your AOCC installation. **Replace `AOCC_LOC` with
 the location you found earlier**:

 ```yaml
 compilers:
  - compiler:
      spec: aocc@5.2.0
      paths:
        cc: AOCC_LOC/bin/clang-17
        cxx: AOCC_LOC/bin/clang++
        f77: AOCC_LOC/bin/flang
        fc: AOCC_LOC/bin/flang
      flags:
        cflags: -march=znver2
        cxxflags: -march=znver2
        fflags: -march=znver2
      environment: {}
      extra_rpaths:
        - AOCC_LOC/lib
 ```

* Compile HPCG:

```bash
spack install --dirty hpcg +openmp aocc@5.2.0 ^openmpi fabrics=cma,ucx
```

* Because AOCC was patched to use a non-standard glibc, you will need to set
the dynamic link path to include this. Set LD_LIBRARY_PATH before executing
the AOCC compiled version of HPCG e.g:

```bash
LD_LIBRARY_PATH="$AOCC_LOC/lib:$LD_LIBRARY_PATH" ./xhpcg
```

### Notes on HPCG

* For comparable results, aim to use ~25% of the compute node's memory
capacity, across all tasks
* Memory capacity by node type, as reported by `free`:

 | Node type | Total memory capacity (bytes) |
 |-----------|-------------------------------|
 | normal    | 201326964736                  |
 | amd01     | 270269554688                  |
 | amd02     | 270141579264                  |
 | icx       | 270076346368                  |
 | gnr       | 1622905081856                 |

* Bytes/equation for HPCG on NEXTGenIO normal partition compute nodes, icx and
amd are ~715, and ~839 for ILP64 HCPG builds (i.e. gnr).

* The local problem size is defined in `hpcg.dat` and should scale with the
number of tasks/node (i.e. shrink with more tasks if you wish to maintain ~25%
memory capacity use) and be a multiple of 8. Further information is
available here:
<https://www.intel.com/content/www/us/en/docs/onemkl/developer-guide-linux/2026-0/choosing-the-best-configuration-and-problem-sizes.html>

* When running the AMD optimised benchmark, don't forget to unload any existing
MPI implementation as spack supplies an AOCC optimised OpenMPI e.g.

```bash
module unload mpi openmpi mpich
spack load hpcg
# ...
```

* A reliable (except on gnr) ceiling I found for the standard HPCG build's
problem size is 424^3 on the NextGenIO systems. Any larger than this will
require a build with 64-bit global indices (ILP64).

## OSU Micro-Benchmarks (OMB)

<https://mvapich.cse.ohio-state.edu/benchmarks/>

### Building and running the OSU Micro-Benchmarks with oneAPI + Intel MPI

* Load modules needed to build and run OMB:

```bash
module load packages-nextgenio packages-oneapi compiler/2023.0.0 mpi/2021.15
```

* Download and extract the latest tarball from the main page above (at the time
 of writing this is version 7.5.2):

```bash
cd ~/benchmarks
wget http://mvapich.cse.ohio-state.edu/download/mvapich/osu-micro-benchmarks-7.5.2.tar.gz
tar xzf osu-micro-benchmarks-7.5.2.tar.gz
cd osu-micro-benchmarks-7.5.2
```

* Set prefix to a directory of your choice (in this case `omb_7.5.2_build`)

```bash
mkdir -p ~/benchmarks/omb_7.5.2_build
./configure CC=mpiicx CXX=mpiicpx --prefix="$HOME/benchmarks/omb_7.5.2_build"
```

* Run Make

```bash
make
make install
```

## Possible future work

* Fully explore how CPU affinity settings across MPI implementations and SLURM
 affect benchmark or solver performance. Informal testing over the course of
 this project suggests it can have a major impact on performance.
* Use hermetic builds of the benchmarks to rule out interference from the
 environment.
* Further exploration of inter-node benchmarking and factors affecting their
performance.

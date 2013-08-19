/** @file common.cu implementation of common library for Halloc testing */

#include <limits.h>
#include <omp.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <unistd.h>

#include <thrust/iterator/counting_iterator.h>
#include <thrust/device_ptr.h>
#include <thrust/logical.h>
#include <thrust/functional.h>

#include "common.h"

// parsing options
const char *opts_usage_g = 
	"usage: <test-name> <options>\n"
	"\n"
	"supported options are to be added later\n";

void print_usage_and_exit(int exit_code) {
	printf("%s", opts_usage_g);
	exit(exit_code);
}  // print_usage_and_exit

double parse_double(char *str, double a = 0.0, double b = 1.0) {
	double r;
	if(sscanf(str, "%lf", &r) != 1) {
		fprintf(stderr, "%s is not a double value\n", str);
		print_usage_and_exit(-1);
	}
	if(r < a || r > b) {
		fprintf(stderr, "double value %lf is not in range [%lf, %lf]\n", r, a, b);
		print_usage_and_exit(-1);
	}
	return r;
}  // parse_double

int parse_int(char *str, int a = INT_MIN, int b = INT_MAX) {
	int r;
	if(sscanf(str, "%d", &r) != 1) {
		fprintf(stderr, "%s is not an integer value or too big\n", &r);
		print_usage_and_exit(-1);
	}
	if(r < a || r > b) {
		fprintf(stderr, "integer value %d is not in range [%d, %d]\n", r, a, b);
		print_usage_and_exit(-1);
	}
	return r;
}  // parse_int

char *allocator_types[] = {
	"cuda", "halloc", "scatteralloc", "xmalloc"
};

AllocatorType parse_allocator(char *str) {
	int istr;
	for(istr = 0; istr < AllocatorTopNone - 1; istr++)
		if(!strcmp(str, allocator_types[istr]))
			break;
	istr++;
	if(istr == AllocatorTopNone) {
		printf("%s: invalid allocator name\n", str);
		print_usage_and_exit(-1);
	}
	return (AllocatorType)istr;
}  // parse_allocator

void CommonOpts::parse_cmdline(int argc, char **argv) {
	static const char *common_opts_str = ":ha:m:C:B:R:S:b:D:n:t:s:l:f:p:";
	int c;
	int period_sh, ndevices;
	cucheck(cudaGetDeviceCount(&ndevices));
	bool nthreads_explicit = false;
	while((c = getopt(argc, argv, common_opts_str)) != -1) {
		switch(c) {
			// general options (and errors)
		case 'h':
			print_usage_and_exit(0);
			break;
		case ':':
			fprintf(stderr, "missing argument for option %c\n", optopt);
			print_usage_and_exit(-1);
			break;
		case '?':
			fprintf(stderr, "unknown option -%c\n", optopt);
			print_usage_and_exit(-1);
			break;

			// allocator options
		case 'a':
			allocator = parse_allocator(optarg);
			break;
		case 'm':
			memory = parse_int(optarg, 4096);
			break;
		case 'C':
			halloc_fraction = parse_double(optarg);
			break;
		case 'B':
			busy_fraction = parse_double(optarg);
			break;
		case 'R':
			roomy_fraction = parse_double(optarg);
			break;
		case 'S':
			sparse_fraction = parse_double(optarg);
			break;
		case 'b':
			sb_sz_sh = parse_int(optarg, 20, 26);
			break;

			// test options
		case 'D':
			device = parse_int(optarg, 0, ndevices - 1);
			break;
		case 'n':
			nthreads = parse_int(optarg, 0);
			nthreads_explicit = true;
			break;
		case 't':
			ntries = parse_int(optarg, 1);
			break;
		case 's':
			alloc_sz = parse_int(optarg, 0);
			break;
		case 'l':
			nallocs = parse_int(optarg, 1);
			break;
		case 'f':
			alloc_fraction = parse_double(optarg);
			break;
		case 'p':
			period_sh = parse_int(optarg, 0, 31);
			period_mask = period_sh > 0 ? ((1 << period_sh) - 1) : 0;
			break;

		default:
			fprintf(stderr, "this simply should not happen when parsing options\n");
			print_usage_and_exit(-1);
			break;
		}  // switch
	}

	// cap memory to fraction of device memory
	int device;
	cucheck(cudaGetDevice(&device));
	cudaDeviceProp props;
	cucheck(cudaGetDeviceProperties(&props, device));
	size_t dev_memory = props.totalGlobalMem;
	memory = min((unsigned long long)memory, 
							 (unsigned long long)(0.75 * dev_memory));

	// cap number of threads for CUDA allocator
	if(allocator == AllocatorCuda && !nthreads_explicit)
		nthreads = min(nthreads, 32 * 1024);
}  // parse_cmdline

double CommonOpts::total_nallocs(void) {
	int period = period_mask + 1;
	return (double)nthreads * ntries * nallocs / period;
}

struct ptr_is_nz {
	void **ptrs;
	int period;
	__host__ __device__ ptr_is_nz(void **ptrs, int period) {
		this->ptrs = ptrs;
		this->period = period;
	}
	__host__ __device__ bool operator()(int i) { 
		if(i % period == 0) 
			return ptrs[i] != 0;
		else
			return true;
	}
};

bool check_nz(void **d_ptrs, int nptrs, int period) {
	//thrust::device_ptr<void *> dt_ptrs(d_ptrs);
	return thrust::all_of
		(thrust::counting_iterator<int>(0), thrust::counting_iterator<int>(nptrs),
		 ptr_is_nz(d_ptrs, period));
}  // check_nz

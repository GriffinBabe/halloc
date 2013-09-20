NAME=libhalloc.a
SRC_C=src/*.cu
SRC_H=src/*.h src/*.cuh
SRC=$(SRC_C) $(SRC_H)
TGT=bin/$(NAME)

#TEST_TGT=tst/corr/bin/test

TMP=*~ \\\#* src/*~ src/\\\#* tst/corr/*~ tst/corr/*.o $(TGT) $(TEST_TGT)

build: $(TGT)
$(TGT):	$(SRC) makefile
	nvcc -arch=sm_35 -O3 -lib -rdc=true -o $(TGT) $(SRC_C)
#	nvcc -arch=sm_35 -O3 -lib -rdc=true -o $(TGT) $(SRC_C)
#	nvcc -g -G -arch=sm_35 -O3 -lib -rdc=true -o $(TGT) $(SRC_C)

#test: $(TGT) makefile
#	make -C tst/corr/test run
test:	$(TGT) makefile build-corr
	make -C tst/corr run-only

clean:
	rm -f $(TMP)
	make -C tst/common clean
	make -C tst/corr clean
	make -C tst/perf clean

build-perf:	$(TGT)
	make -C tst/common build
	make -C tst/perf build

build-corr:	$(TGT)
	make -C tst/common build
	make -C tst/corr build

build-test:	$(TGT)
	make -C tst/common build
	make -C tst/corr build
	make -C tst/perf build

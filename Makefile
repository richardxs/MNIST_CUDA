CUDA_PATH=/usr/local/cuda
HOST_COMPILER ?= g++
NVCC=${CUDA_PATH}/bin/nvcc -ccbin ${HOST_COMPILER}
TARGET=cnn

INCLUDES = -I${CUDA_PATH}/samples/common/inc -I$(CUDA_PATH)/include
NVCC_FLAGS=-G --resource-usage -Xcompiler -rdynamic -Xcompiler -fopenmp -rdc=true -lnvToolsExt

IS_CUDA_11:=$(shell echo `nvcc --version | grep compilation | grep -Eo -m 1 '[0-9]+.[0-9]' | head -1` \>= 11.0 | bc)

# Gencode argumentes
SMS = 35 37 50 52 60 61 70 75
ifeq "$(IS_CUDA_11)" "1"
SMS = 52 60 61 70 75 80
endif
$(foreach sm, ${SMS}, $(eval GENCODE_FLAGS += -gencode arch=compute_$(sm),code=sm_$(sm)))

LIBRARIES += -L/usr/local/cuda/lib -lcublas -lcudnn -lgomp -lcurand
ALL_CCFLAGS += -m64 -g -std=c++11 $(NVCC_FLAGS) $(INCLUDES) $(LIBRARIES)

INC_DIR = include
SRC_DIR = src
OBJ_DIR = obj

all : ${TARGET}

INCS = ${INC_DIR}/helper.h ${INC_DIR}/blob.h ${INC_DIR}/loss.h ${INC_DIR}/layer.h ${INC_DIR}/loss.h ${INC_DIR}/mnist.h ${INC_DIR}/network.h

${OBJ_DIR}/%.o: ${SRC_DIR}/%.cpp ${INC_DIR}/%.h
	$(NVCC) $(INCLUDES) $(ALL_CCFLAGS) $(GENCODE_FLAGS) -c $< -o $@
${OBJ_DIR}/%.o: ${SRC_DIR}/%.cu ${INC_DIR}/%.h
	$(NVCC) $(INCLUDES) $(ALL_CCFLAGS) $(GENCODE_FLAGS) -c $< -o $@

${OBJ_DIR}/cnn.o: cnn.cpp ${INCS}
	@mkdir -p $(@D)
	$(NVCC) $(INCLUDES) $(ALL_CCFLAGS) $(GENCODE_FLAGS) -c $< -o $@

OBJS = ${OBJ_DIR}/cnn.o ${OBJ_DIR}/mnist.o ${OBJ_DIR}/loss.o ${OBJ_DIR}/layer.o ${OBJ_DIR}/network.o 

cnn: $(OBJS)
	$(EXEC) $(NVCC) $(ALL_CCFLAGS) $(GENCODE_FLAGS) -o $@ $+


.PHONY: clean
clean:
	rm -f ${TARGET} ${OBJ_DIR}/*.o


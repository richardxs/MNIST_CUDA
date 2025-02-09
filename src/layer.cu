#include "../include/layer.h"

#include <random>

#include <cuda_runtime.h>
#include <curand.h>
#include <cassert>
#include <math.h>
#include <algorithm>

#include <sstream>
#include <fstream>
#include <iostream>

using namespace cudl;

#define CUDA_1D_KERNEL_LOOP(i, n)                                 \
  for (size_t i = blockIdx.x * blockDim.x + threadIdx.x; i < (n); \
       i += blockDim.x * gridDim.x)

__global__ void add(float *array_a, float *array_b, float *array_c, int size) {
    int tid = blockIdx.x * blockDim.x + threadIdx.x;
    int step = blockDim.x * gridDim.x;

    for (int i = tid; i < size; i += step) {
        array_c[i] = array_a[i] + array_b[i];
    }
}

__global__ void adam_update(
        int N,
        int step,
        float *m,
        float *v,
        float *w,
        const float *g,
        const float beta1,
        const float beta2,
        const float eps_hat,
        const float lr) {
    CUDA_1D_KERNEL_LOOP(i, N) {
        // Updating running mean and var.
        m[i] = m[i] * beta1 + g[i] * (1 - beta1);
        v[i] = v[i] * beta2 + g[i] * g[i] * (1 - beta2);
        float mi = m[i] / (1 - std::pow(beta1, step + 1));
        float vi = v[i] / (1 - std::pow(beta2, step + 1));
        // Update parameters.
        w[i] = w[i] - lr * mi / (std::sqrt(vi) + eps_hat);
    }
}

__global__ void rmsprop_update(
        int N,
        float *m,
        float *w,
        const float *g,
        const float decay,
        const float eps_hat,
        const float lr) {
    CUDA_1D_KERNEL_LOOP(i, N) {
        // Updating running mean and var.
        m[i] = m[i] + (1 - decay) * (g[i] * g[i] - m[i]);
        // Update parameters.
        w[i] = w[i] - lr * g[i] / std::sqrt(eps_hat + m[i]);
    }
}

/****************************************************************
 * Layer definition                                             *
 ****************************************************************/
Layer::Layer() {
    /* do nothing */
}

Layer::~Layer() {
#if (DEBUG_FORWARD > 0 || DEBUG_BACKWARD > 0)
    std::cout << "Destroy Layer: " << name_ << std::endl;
#endif

    if (output_ != nullptr) delete output_;
    if (grad_input_ != nullptr) delete grad_input_;

    if (weights_ != nullptr) delete weights_;
    if (biases_ != nullptr) delete biases_;
    if (weights_m_ != nullptr) delete weights_m_;
    if (biases_m_ != nullptr) delete biases_m_;
    if (weights_v_ != nullptr) delete weights_v_;
    if (biases_v_ != nullptr) delete biases_v_;
    if (grad_weights_ != nullptr) delete grad_weights_;
    if (grad_biases_ != nullptr) delete grad_biases_;
}

void Layer::init_weight_bias(unsigned int seed) {
    checkCudaErrors(cudaDeviceSynchronize());

    if (weights_ == nullptr || biases_ == nullptr)
        return;

    // Create random network
    std::random_device rd;
    std::mt19937 gen(seed == 0 ? rd() : static_cast<unsigned int>(seed));

    // He uniform distribution
    float range = sqrt(6.f / input_->size());    // He's initialization
    std::uniform_real_distribution<> dis(-range, range);

    for (int i = 0; i < weights_->len(); i++)
        weights_->ptr()[i] = static_cast<float>(dis(gen));
    for (int i = 0; i < biases_->len(); i++)
        biases_->ptr()[i] = 0.f;

    for (int i = 0; i < weights_m_->len(); i++)
        weights_m_->ptr()[i] = 0.f;
    for (int i = 0; i < weights_v_->len(); i++)
        weights_v_->ptr()[i] = 0.f;
    for (int i = 0; i < biases_m_->len(); i++)
        biases_m_->ptr()[i] = 0.f;
    for (int i = 0; i < biases_v_->len(); i++)
        biases_v_->ptr()[i] = 0.f;

    // copy initialized value to the device
    weights_->to(DeviceType::cuda);
    biases_->to(DeviceType::cuda);
    weights_m_->to(DeviceType::cuda);
    weights_v_->to(DeviceType::cuda);
    biases_->to(DeviceType::cuda);
    biases_m_->to(DeviceType::cuda);
    biases_v_->to(DeviceType::cuda);

    std::cout << ".. initialized " << name_ << " layer .." << std::endl;
}

void Layer::update_weights_biases(float learning_rate) {
    float eps = -1.f * learning_rate;
    if (weights_ != nullptr && grad_weights_ != nullptr) {
#if (DEBUG_UPDATE)
        weights_->print(name_ + "::weights (before update)", true);
        grad_weights_->print(name_ + "::gweights", true);
#endif // DEBUG_UPDATE

        // w = w + eps * dw
        checkCublasErrors(
                cublasSaxpy(cuda_->cublas(),
                            weights_->len(),
                            &eps,
                            grad_weights_->cuda(), 1,
                            weights_->cuda(), 1));

#if (DEBUG_UPDATE)
        weights_->print(name_ + "weights (after update)", true);
        // getchar();
#endif // DEBUG_UPDATE
    }

    if (biases_ != nullptr && grad_biases_ != nullptr) {
#if (DEBUG_UPDATE)
        biases_->print(name_ + "biases (before update)", true);
        grad_biases_->print(name_ + "gbiases", true);
#endif // DEBUG_UPDATE

        // b = b + eps * db
        checkCublasErrors(
                cublasSaxpy(cuda_->cublas(),
                            biases_->len(),
                            &eps,
                            grad_biases_->cuda(), 1,
                            biases_->cuda(), 1));

#if (DEBUG_UPDATE)
        biases_->print(name_ + "biases (after update)", true);
        // getchar();
#endif // DEBUG_UPDATE
    }
}

void Layer::update_weights_biases_with_adam(float learning_rate, float beta1, float beta2, float eps_hat, int step) {

    if (weights_ != nullptr && grad_weights_ != nullptr) {

#if (DEBUG_UPDATE)
        weights_->print(name_ + "::weights (before update)", true);
        grad_weights_->print(name_ + "::gweights", true);
#endif // DEBUG_UPDATE
        /*
         * mt = b1*mt + (1-b1)*dw
         * vt = b2*vt + (1-b2)*dw*dw
         * mtt = mt/(1-(b1^(i+1)))
         * vtt = vt/(1-(b2^(i+1)))
         * w = w + eps * mtt/(std::sqrt(vtt) + e)
         */

        adam_update << < 16, BLOCK_DIM_1D >> >
                             (weights_->len(), step, weights_m_->cuda(), weights_v_->cuda(), weights_->cuda(), grad_weights_->cuda(), beta1, beta2, eps_hat, learning_rate);


#if (DEBUG_UPDATE)
        weights_->print(name_ + "weights (after update)", true);
        // getchar();
#endif // DEBUG_UPDATE
    }

    if (biases_ != nullptr && grad_biases_ != nullptr) {
#if (DEBUG_UPDATE)
        biases_->print(name_ + "biases (before update)", true);
        grad_biases_->print(name_ + "gbiases", true);
#endif // DEBUG_UPDATE

        adam_update << < 16, BLOCK_DIM_1D >> >
                             (biases_->len(), step, biases_m_->cuda(), biases_v_->cuda(), biases_->cuda(), grad_biases_->cuda(), beta1, beta2, eps_hat, learning_rate);

#if (DEBUG_UPDATE)
        biases_->print(name_ + "biases (after update)", true);
        // getchar();
#endif // DEBUG_UPDATE
    }
}

void Layer::update_weights_biases_with_rmsprop(float learning_rate, float decay, float eps_hat) {

    if (weights_ != nullptr && grad_weights_ != nullptr) {

#if (DEBUG_UPDATE)
        weights_->print(name_ + "::weights (before update)", true);
        grad_weights_->print(name_ + "::gweights", true);
#endif // DEBUG_UPDATE
        /*
         * mt = mt + (1-decay)*(dw*dw-mt)
         * w = w - learning_rate * dw /std::sqrt(eps_hat+mt)
         */

        rmsprop_update << < BLOCK_DIM, BLOCK_DIM_1D >> >
                                       (weights_->len(), weights_m_->cuda(), weights_->cuda(), grad_weights_->cuda(), decay, eps_hat, learning_rate);


#if (DEBUG_UPDATE)
        weights_->print(name_ + "weights (after update)", true);
        // getchar();
#endif // DEBUG_UPDATE
    }

    if (biases_ != nullptr && grad_biases_ != nullptr) {
#if (DEBUG_UPDATE)
        biases_->print(name_ + "biases (before update)", true);
        grad_biases_->print(name_ + "gbiases", true);
#endif // DEBUG_UPDATE

        rmsprop_update << < BLOCK_DIM, BLOCK_DIM_1D >> >
                                       (weights_->len(), weights_m_->cuda(), weights_->cuda(), grad_weights_->cuda(), decay, eps_hat, learning_rate);

#if (DEBUG_UPDATE)
        biases_->print(name_ + "biases (after update)", true);
        // getchar();
#endif // DEBUG_UPDATE
    }
}

float Layer::get_loss(Blob<float> *target) {
    assert("No Loss layer has no loss." && false);
    return EXIT_FAILURE;
}

int Layer::get_accuracy(Blob<float> *target) {
    assert("No Loss layer cannot estimate accuracy." && false);
    return EXIT_FAILURE;
}

int Layer::load_parameter() {
    std::stringstream filename_weights, filename_biases;

    // load weights and biases pretrained parameters
    filename_weights << name_ << ".bin";
    if (weights_->file_read(filename_weights.str()))
        return -1;

    filename_biases << name_ << ".bias.bin";
    if (biases_->file_read(filename_biases.str()))
        return -2;

    std::cout << ".. loaded " << name_ << " pretrain parameter.." << std::endl;

    return 0;
}

int Layer::save_parameter() {
    std::stringstream filename_weights, filename_biases;

    std::cout << ".. saving " << name_ << " parameter ..";

    // Write weights file
    if (weights_) {
        filename_weights << name_ << ".bin";
        if (weights_->file_write(filename_weights.str()))
            return -1;
    }

    // Write bias file
    if (biases_) {
        filename_biases << name_ << ".bias.bin";
        if (biases_->file_write(filename_biases.str()))
            return -2;
    }

    std::cout << " done .." << std::endl;

    return 0;
}

/****************************************************************
 * Linear Layer                                                  *
 ****************************************************************/

Linear::Linear(std::string name, int output_size) {
    name_ = name;
    output_size_ = output_size;
}

Linear::~Linear() {
    if (d_one_vec != nullptr)
        cudaFree(d_one_vec);
}

__global__ void init_one_vec(float *d_one_vec, size_t length) {
    int i = blockIdx.x * blockDim.x + threadIdx.x;

    if (i >= length) return;

    d_one_vec[i] = 1.f;
}

Blob<float> *Linear::forward(Blob<float> *input) {
    // initialize weights and biases
    if (weights_ == nullptr) {
        // setup parameter size information
        input_size_ = input->c() * input->h() * input->w();

        // initialize weight, bias, and output
        weights_ = new Blob<float>(1, 1, input_size_, output_size_);
        biases_ = new Blob<float>(1, 1, output_size_);

        weights_m_ = new Blob<float>(1, 1, input_size_, output_size_);
        weights_v_ = new Blob<float>(1, 1, input_size_, output_size_);
        biases_m_ = new Blob<float>(1, 1, output_size_);
        biases_v_ = new Blob<float>(1, 1, output_size_);
    }

    // initilaize input and output
    if (input_ == nullptr || batch_size_ != input->n()) {
        input_ = input;
        batch_size_ = input->n();

        if (output_ == nullptr)
            output_ = new Blob<float>(batch_size_, output_size_);
        else
            output_->reset(batch_size_, output_size_);

        output_->tensor();

        if (d_one_vec != nullptr)
            cudaFree(d_one_vec);
        checkCudaErrors(cudaMalloc((void **) &d_one_vec, sizeof(float) * batch_size_));
        init_one_vec << < (batch_size_ + BLOCK_DIM_1D - 1) / BLOCK_DIM_1D, BLOCK_DIM_1D >> > (d_one_vec, batch_size_);

        // initialize weights and biases
        if (load_pretrain_ && !freeze_) {
            if (load_parameter()) {
                std::cout << "error occurred.." << std::endl;
                exit(-1);
            }
        } else if (!freeze_) {
            init_weight_bias();
        } else {
            /* do nothing */
        }
    }

    // output = weights^T * input (without biases)
    checkCublasErrors(
            cublasSgemm(cuda_->cublas(),
                        CUBLAS_OP_T, CUBLAS_OP_N,
                        output_size_, batch_size_, input_size_,
                        &cuda_->one,
                        weights_->cuda(), input_size_,
                        input_->cuda(), input_size_,
                        &cuda_->zero,
                        output_->cuda(), output_size_));

    // output += biases * d_one_vec^T
    checkCublasErrors(cublasSgemm(cuda_->cublas(),
                                  CUBLAS_OP_N, CUBLAS_OP_N,
                                  output_size_, batch_size_, 1,
                                  &cuda_->one,
                                  biases_->cuda(), output_size_,
                                  d_one_vec, 1,
                                  &cuda_->one,
                                  output_->cuda(), output_size_));


#if (DEBUG_LINEAR & 0x01)
    input_->print(  name_ + "::input",  true);
    weights_->print(name_ + "::weight", true);
    biases_->print( name_ + "::bias",   true);
    output_->print( name_ + "::output", true);
#endif // DEBUG_LINEAR

    return output_;
}

Blob<float> *Linear::backward(Blob<float> *grad_output) {
    if (grad_weights_ == nullptr) {
        grad_weights_ = new Blob<float>(weights_->shape());
        grad_biases_ = new Blob<float>(biases_->shape());
    }

    if (grad_input_ == nullptr || batch_size_ != grad_output->n()) {
        grad_output_ = grad_output;

        if (grad_input_ == nullptr)
            grad_input_ = new Blob<float>(input_->shape());
        else
            grad_input_->reset(input_->shape());
    }

    // db = (dy) * d_one_vec
    cublasSgemv(cuda_->cublas(),
                CUBLAS_OP_N,
                output_size_, batch_size_,
                &cuda_->one,
                grad_output_->cuda(), output_size_,
                d_one_vec, 1,
                &cuda_->zero,
                grad_biases_->cuda(), 1);

    // dw = x * (dy)^T
    cublasSgemm(cuda_->cublas(),
                CUBLAS_OP_N, CUBLAS_OP_T,
                input_size_, output_size_, batch_size_,
                &cuda_->one,
                input_->cuda(), input_size_,
                grad_output_->cuda(), output_size_,
                &cuda_->zero,
                grad_weights_->cuda(), input_size_);

    // dx = W * dy
    if (!gradient_stop_)
        cublasSgemm(cuda_->cublas(),
                    CUBLAS_OP_N, CUBLAS_OP_N,
                    input_size_, batch_size_, output_size_,
                    &cuda_->one,
                    weights_->cuda(), input_size_,
                    grad_output_->cuda(), output_size_,
                    &cuda_->zero,
                    grad_input_->cuda(), input_size_);

#if (DEBUG_LINEAR & 0x02)
    std::cout << name_ << "[BACKWARD]" << std::endl;
    grad_output->print(  name_ + "::gradients", true, grad_output->n());
    grad_weights_->print(name_ + "::gfilter", true);
    grad_biases_->print( name_ + "::gbias", true);
    if (!gradient_stop_)
        grad_input_->print(  name_ + "::gdata", true);
#endif // DEBUG_LINEAR

    return grad_input_;
}

/****************************************************************
 * Activation Layer                                             *
 ****************************************************************/

Activation::Activation(std::string name, cudnnActivationMode_t mode, float coef) {
    name_ = name;
    mode_ = mode;
    coef_ = coef;

    cudnnCreateActivationDescriptor(&act_desc_);
    cudnnSetActivationDescriptor(act_desc_, mode, CUDNN_PROPAGATE_NAN, coef);
}

Activation::~Activation() {
    cudnnDestroyActivationDescriptor(act_desc_);
}

Blob<float> *Activation::forward(Blob<float> *input) {
    if (input_ == nullptr || batch_size_ != input->n()) {
        input_ = input;
        input_desc_ = input->tensor();
        batch_size_ = input->n();

        if (output_ == nullptr)
            output_ = new Blob<float>(input->shape());
        else
            output_->reset(input->shape());

        output_desc_ = output_->tensor();
    }

    cudnnActivationForward(cuda_->cudnn(),
                           act_desc_,
                           &cuda_->one,
                           input_desc_,
                           input->cuda(),
                           &cuda_->zero,
                           output_desc_,
                           output_->cuda());

    return output_;
}

Blob<float> *Activation::backward(Blob<float> *grad_output) {
    if (grad_input_ == nullptr || batch_size_ != grad_output->n()) {
        grad_output_ = grad_output;

        if (grad_input_ == nullptr)
            grad_input_ = new Blob<float>(input_->shape());
        else
            grad_input_->reset(input_->shape());
    }

    cudnnActivationBackward(cuda_->cudnn(),
                            act_desc_,
                            &cuda_->one,
                            output_desc_, output_->cuda(),
                            output_desc_, grad_output->cuda(),
                            input_desc_, input_->cuda(),
                            &cuda_->zero,
                            input_desc_, grad_input_->cuda());

    return grad_input_;
}

/****************************************************************
 * Softmax definition                                           *
 ****************************************************************/

Softmax::Softmax(std::string name) {
    name_ = name;
}

Softmax::~Softmax() {

}

Blob<float> *Softmax::forward(Blob<float> *input) {
    if (input_ == nullptr || batch_size_ != input->n()) {
        input_ = input;
        input_desc_ = input->tensor();
        batch_size_ = input->n();

        if (output_ == nullptr)
            output_ = new Blob<float>(input->shape());
        else
            output_->reset(input->shape());

        output_desc_ = output_->tensor();
    }

#if (DEBUG_SOFTMAX & 0x01)
        std::cout << name_ << "[FORWARD]" << std::endl;
        input_->print(name_ + "::input", true, input->n());
#endif

    checkCudnnErrors(
            cudnnSoftmaxForward(cuda_->cudnn(), CUDNN_SOFTMAX_ACCURATE, CUDNN_SOFTMAX_MODE_CHANNEL,
                                &cuda_->one, input_desc_, input->cuda(),
                                &cuda_->zero, output_desc_, output_->cuda()));

#if (DEBUG_SOFTMAX & 0x01)
    output_->print(name_ + "::output", true, input->n());
#endif

    return output_;
}

Blob<float> *Softmax::backward(Blob<float> *target) {
    checkCudaErrors(cudaDeviceSynchronize());

    if (grad_input_ == nullptr || batch_size_ != target->n()) {
        if (grad_input_ == nullptr)
            grad_input_ = new Blob<float>(input_->shape());
        else
            grad_input_->reset(input_->shape());
    }

    // set grad_input_ as predict
    checkCudaErrors(cudaMemcpyAsync(grad_input_->cuda(),
                                    output_->cuda(), output_->buf_size(),
                                    cudaMemcpyDeviceToDevice));
    // set grad_input_ = predict - target
    checkCublasErrors(
            cublasSaxpy(cuda_->cublas(), target->len(),
                        &cuda_->minus_one, target->cuda(), 1,
                        grad_input_->cuda(), 1));

    // normalize the grad_output by the batch size
    int grad_output_size = target->n() * target->c() * target->h() * target->w();
    float scale = 1.f / static_cast<float>(target->n());
    checkCublasErrors(cublasSscal(cuda_->cublas(), grad_output_size, &scale, grad_input_->cuda(), 1));

#if (DEBUG_SOFTMAX & 0x02)
    std::cout << name_ << "[BACKWARD]" << std::endl;
    input_->print( name_ + "::input", true);
    output_->print(name_ + "::predict", true);
    target->print( name_ + "::y", true, target->n());
    grad_input_->print(name_ + "::dx", true, target->n());
#endif

    return grad_input_;
}

float Softmax::get_loss(Blob<float> *target) {
    return loss_.loss(output_, target);
}

int Softmax::get_accuracy(Blob<float> *target) {
    int batch_size = output_->n();
    int output_size = output_->size();

    assert(batch_size == target->n());
    assert(output_size == target->size());

    float *h_output, *h_target;
    int idx_output, idx_target;
    int hit_count = 0;

    // get predicts and targets
    h_output = output_->to(host);
    h_target = target->to(host);

    // idx_output = idx_target = 0;
    for (int b = 0; b < batch_size; b++) {
        idx_output = 0;
        idx_target = 0;

        for (int i = 1; i < 10; i++) {
            if (h_output[b * output_size + i] > h_output[b * output_size + idx_output])
                idx_output = i;
            if (h_target[b * output_size + i] > h_target[b * output_size + idx_target])
                idx_target = i;
        }

        if (idx_output == idx_target)
            hit_count++;
    }

    return hit_count;
}

/****************************************************************
 * Layer definition                                             *
 ****************************************************************/

/**
 * Convolutional layer with bias
 */
Conv2D::Conv2D(std::string name,
               int out_channels,
               int kernel_size,
               int stride,
               int padding,
               int dilation) :
        out_channels_(out_channels),
        kernel_size_(kernel_size),
        stride_(stride),
        padding_(padding),
        dilation_(dilation) {
    name_ = name;

    // create cudnn container handles
    cudnnCreateFilterDescriptor(&filter_desc_);

    cudnnCreateConvolutionDescriptor(&conv_desc_);
    checkCudnnErrors(cudnnSetConvolution2dDescriptor(conv_desc_,
                                                     padding_, padding_, stride_, stride_, dilation_, dilation_,
                                                     CUDNN_CROSS_CORRELATION, CUDNN_DATA_FLOAT));
}

Conv2D::~Conv2D() {
    // distroy cudnn container resources
    cudnnDestroyFilterDescriptor(filter_desc_);
    cudnnDestroyConvolutionDescriptor(conv_desc_);

    // terminate internal created blobs
    if (d_workspace != nullptr) cudaFree(d_workspace);
}

void Conv2D::set_workspace()
{
	size_t temp_size = 0;

	cudnnConvolutionFwdAlgoPerf_t 		fwd_algo_perf_results[CUDNN_CONVOLUTION_FWD_ALGO_COUNT];
	cudnnConvolutionBwdFilterAlgoPerf_t 	bwd_filter_algo_perf_results[CUDNN_CONVOLUTION_BWD_FILTER_ALGO_COUNT];
	cudnnConvolutionBwdDataAlgoPerf_t	bwd_data_algo_perf_results[CUDNN_CONVOLUTION_BWD_DATA_ALGO_COUNT];

	// forward
#if CUDNN_MAJOR == 8
	int algo_max_count;
	checkCudnnErrors(cudnnGetConvolutionForwardAlgorithmMaxCount(cuda_->cudnn(), &algo_max_count));
	std::cout << this->name_ << ": Available Algorithm Count [FWD]: " << algo_max_count << std::endl;
	checkCudnnErrors(cudnnGetConvolutionForwardAlgorithm_v7(cuda_->cudnn(),
		input_desc_, filter_desc_, conv_desc_, output_desc_,
		algo_max_count, 0, fwd_algo_perf_results));
	conv_fwd_algo_ = fwd_algo_perf_results[0].algo;
#else
	checkCudnnErrors(cudnnGetConvolutionForwardAlgorithm(cuda_->cudnn(),
		input_desc_, filter_desc_, conv_desc_, output_desc_,
		CUDNN_CONVOLUTION_FWD_PREFER_FASTEST, 0, &conv_fwd_algo_));
#endif
	checkCudnnErrors(cudnnGetConvolutionForwardWorkspaceSize(cuda_->cudnn(),
		input_desc_, filter_desc_, conv_desc_, output_desc_,
		conv_fwd_algo_, &temp_size));
	workspace_size = std::max(workspace_size, temp_size);

	// bwd - filter
#if CUDNN_MAJOR == 8
	checkCudnnErrors(cudnnGetConvolutionBackwardFilterAlgorithmMaxCount(cuda_->cudnn(), &algo_max_count));
	std::cout << this->name_ << ": Available Algorithm Count [BWD-filter]: " << algo_max_count << std::endl;
	checkCudnnErrors(cudnnGetConvolutionBackwardFilterAlgorithm_v7(cuda_->cudnn(),
		input_desc_, output_desc_, conv_desc_, filter_desc_,
		algo_max_count, 0, bwd_filter_algo_perf_results));
	conv_bwd_filter_algo_ = bwd_filter_algo_perf_results[0].algo;
#else
	checkCudnnErrors(cudnnGetConvolutionBackwardFilterAlgorithm(cuda_->cudnn(),
		input_desc_, output_desc_, conv_desc_, filter_desc_,
		CUDNN_CONVOLUTION_BWD_FILTER_PREFER_FASTEST, 0, &conv_bwd_filter_algo_));
#endif
	checkCudnnErrors(cudnnGetConvolutionBackwardFilterWorkspaceSize(cuda_->cudnn(),
		input_desc_, output_desc_, conv_desc_, filter_desc_,
		conv_bwd_filter_algo_, &temp_size));
	workspace_size = std::max(workspace_size, temp_size);

	// bwd - data
#if CUDNN_MAJOR == 8
	checkCudnnErrors(cudnnGetConvolutionBackwardDataAlgorithmMaxCount(cuda_->cudnn(), &algo_max_count));
	std::cout << this->name_ << ": Available Algorithm Count [BWD-data]: " << algo_max_count << std::endl;
	checkCudnnErrors(cudnnGetConvolutionBackwardDataAlgorithm_v7(cuda_->cudnn(),
		filter_desc_, output_desc_, conv_desc_, input_desc_,
		algo_max_count, 0, bwd_data_algo_perf_results));
	conv_bwd_data_algo_ = bwd_data_algo_perf_results[0].algo;
#else
	checkCudnnErrors(cudnnGetConvolutionBackwardDataAlgorithm(cuda_->cudnn(), 
		filter_desc_, output_desc_, conv_desc_, input_desc_, 
		CUDNN_CONVOLUTION_BWD_DATA_PREFER_FASTEST, 0, &conv_bwd_data_algo_));
#endif
	checkCudnnErrors(cudnnGetConvolutionBackwardDataWorkspaceSize(cuda_->cudnn(),
		filter_desc_, output_desc_, conv_desc_, input_desc_,
		conv_bwd_data_algo_, &temp_size));
	workspace_size = std::max(workspace_size, temp_size);

	if (workspace_size > 0)
	{
		if (d_workspace != nullptr)
			checkCudaErrors(cudaFree(d_workspace));
		checkCudaErrors(cudaMalloc((void**)&d_workspace, workspace_size));
	}
}

Blob<float> *Conv2D::forward(Blob<float> *input) {
    // initialize weights and bias
    if (weights_ == nullptr) {
        // initialize containers handles
        checkCudnnErrors(cudnnSetFilter4dDescriptor(filter_desc_,
                                                    CUDNN_DATA_FLOAT, CUDNN_TENSOR_NCHW,
                                                    out_channels_, input->c(), kernel_size_, kernel_size_));

        weights_ = new Blob<float>(out_channels_, input->c(), kernel_size_, kernel_size_);
        biases_ = new Blob<float>(1, out_channels_);    // bias size

        weights_m_ = new Blob<float>(out_channels_, input->c(), kernel_size_, kernel_size_);
        weights_v_ = new Blob<float>(out_channels_, input->c(), kernel_size_, kernel_size_);
        biases_m_ = new Blob<float>(1, out_channels_);
        biases_v_ = new Blob<float>(1, out_channels_);

        bias_desc_ = biases_->tensor();
    }

    // initilaize input and output
    if (input_ == nullptr || batch_size_ != input->n()) {
        // initialize input
        input_ = input;
        input_desc_ = input->tensor();
        batch_size_ = input->n();

        // initilaize output
        checkCudnnErrors(cudnnGetConvolution2dForwardOutputDim(
                conv_desc_, input_desc_, filter_desc_,
                &output_size_[0], &output_size_[1], &output_size_[2], &output_size_[3]));
        if (output_ == nullptr)
            output_ = new Blob<float>(output_size_);
        else
            output_->reset(output_size_);

        output_desc_ = output_->tensor();

        // initialize workspace for cudnn
        set_workspace();

        // initialize weights
        if (load_pretrain_ && !freeze_) {
            if (load_parameter()) {
                std::cout << "error occurred.." << std::endl;
                exit(-1);
            }
        } else if (!freeze_) {
            init_weight_bias();
        } else {
            /* do nothing */
        }
    }

    checkCudnnErrors(cudnnConvolutionForward(cuda_->cudnn(),
                                             &cuda_->one, input_desc_, input_->cuda(),
                                             filter_desc_, weights_->cuda(), conv_desc_, conv_fwd_algo_, d_workspace,
                                             workspace_size,
                                             &cuda_->zero, output_desc_, output_->cuda()));

    checkCudnnErrors(cudnnAddTensor(cuda_->cudnn(),
                                    &cuda_->one, bias_desc_, biases_->cuda(),
                                    &cuda_->one, output_desc_, output_->cuda()));

#if (DEBUG_CONV & 0x01)
    input_->print(  name_ + "::input", true, input_->n(), 28);
    weights_->print(name_ + "::weight", true);
    biases_->print( name_ + "::bias", true);
    output_->print( name_ + "::output", true);
#endif

    return output_;
}

Blob<float> *Conv2D::backward(Blob<float> *grad_output) {
    // initialize grad_output back-propagation space
    if (grad_input_ == nullptr || batch_size_ != grad_output->n()) {
        grad_output_ = grad_output;
        grad_weights_ = new Blob<float>(weights_->shape());
        grad_biases_ = new Blob<float>(1, biases_->c());

        if (grad_input_ == nullptr)
            grad_input_ = new Blob<float>(input_->shape());
        else
            grad_input_->reset(input_->shape());
    }

    // gradients of biases
    checkCudnnErrors(
            cudnnConvolutionBackwardBias(cuda_->cudnn(),
                                         &cuda_->one,
                                         output_desc_, grad_output->cuda(),
                                         &cuda_->zero,
                                         bias_desc_, grad_biases_->cuda()));

    // gradients of weights
    checkCudnnErrors(
            cudnnConvolutionBackwardFilter(cuda_->cudnn(),
                                           &cuda_->one,
                                           input_desc_, input_->cuda(),
                                           output_desc_, grad_output_->cuda(),
                                           conv_desc_, conv_bwd_filter_algo_, d_workspace, workspace_size,
                                           &cuda_->zero,
                                           filter_desc_, grad_weights_->cuda()));

    // gradients of input data
    if (!gradient_stop_) checkCudnnErrors(
            cudnnConvolutionBackwardData(cuda_->cudnn(),
                                         &cuda_->one,
                                         filter_desc_, weights_->cuda(),
                                         output_desc_, grad_output->cuda(),
                                         conv_desc_, conv_bwd_data_algo_, d_workspace, workspace_size,
                                         &cuda_->zero,
                                         input_desc_, grad_input_->cuda()));

#if (DEBUG_CONV & 0x02)
    std::cout << name_ << "[BACKWARD]" << std::endl;
    grad_output->print( name_ + "::gradients", true);
    grad_biases_->print(name_ + "gbias", true);
    grad_weights_->print(name_+ "gfilter", true);
    if (!gradient_stop_)
        grad_input_->print(name_+"gdata", true);
#endif

#if (DEBUG_CONV & 0x04)
    grad_output->print( name_ + "::gradients", true);
    grad_biases_->print( name_ + "::gbias", true);
#endif

    return grad_input_;
}

/****************************************************************
 * Layer definition                                             *
 ****************************************************************/

Pooling::Pooling(std::string name,
                 int kernel_size,
                 int padding,
                 int stride,
                 cudnnPoolingMode_t mode) :
        kernel_size_(kernel_size),
        padding_(padding),
        stride_(stride),
        mode_(mode) {
    name_ = name;

    cudnnCreatePoolingDescriptor(&pool_desc_);
    cudnnSetPooling2dDescriptor(pool_desc_, mode_, CUDNN_PROPAGATE_NAN,
                                kernel_size_, kernel_size_, padding_, padding_, stride_, stride_);
}

Pooling::~Pooling() {
    cudnnDestroyPoolingDescriptor(pool_desc_);
}

Blob<float> *Pooling::forward(Blob<float> *input) {
    if (input_ == nullptr || batch_size_ != input->n()) {
        input_ = input;

        // resource initialize
        input_desc_ = input_->tensor();
        batch_size_ = input->n();

        // setting output
        cudnnGetPooling2dForwardOutputDim(pool_desc_, input_desc_,
                                          &output_size_[0], &output_size_[1], &output_size_[2], &output_size_[3]);
        if (output_ == nullptr)
            output_ = new Blob<float>(output_size_);
        else
            output_->reset(output_size_);

        output_desc_ = output_->tensor();
    }

    cudnnPoolingForward(cuda_->cudnn(), pool_desc_,
                        &cuda_->one, input_desc_, input_->cuda(),
                        &cuda_->zero, output_desc_, output_->cuda());

    return output_;
}

Blob<float> *Pooling::backward(Blob<float> *grad_output) {
    if (grad_input_ == nullptr || batch_size_ != grad_output->n()) {
        grad_output_ = grad_output;

        if (grad_input_ == nullptr)
            grad_input_ = new Blob<float>(input_->shape());
        else
            grad_input_->reset(input_->shape());
    }

    checkCudnnErrors(
            cudnnPoolingBackward(cuda_->cudnn(), pool_desc_,
                                 &cuda_->one,
                                 output_desc_, output_->cuda(),
                                 output_desc_, grad_output->cuda(),
                                 input_desc_, input_->cuda(),
                                 &cuda_->zero,
                                 input_desc_, grad_input_->cuda()));

    return grad_input_;
}


/****************************************************************
 * Local Response Normalization definition                      *
 ****************************************************************/

LRN::LRN(std::string name, unsigned lrnN, double lrnAlpha, double lrnBeta, double lrnK) {
    name_ = name;
    lrnN_ = lrnN;
    lrnAlpha_ = lrnAlpha;
    lrnBeta_ = lrnBeta;
    lrnK_ = lrnK;

    checkCudnnErrors(cudnnCreateLRNDescriptor(&normDesc_));
    checkCudnnErrors(cudnnSetLRNDescriptor(normDesc_,
                                           lrnN_,
                                           lrnAlpha_,
                                           lrnBeta_,
                                           lrnK_));
}

LRN::~LRN() {
    cudnnDestroyLRNDescriptor(normDesc_);
}

Blob<float> *LRN::forward(Blob<float> *input) {
    // initilaize input and output
    if (input_ == nullptr || batch_size_ != input->n()) {
        input_ = input;
        batch_size_ = input->n();
        input_desc_ = input_->tensor();

        if (output_ == nullptr)
            output_ = new Blob<float>(input->shape());
        else
            output_->reset(input->shape());
        output_desc_ = output_->tensor();
    }

    checkCudnnErrors(cudnnLRNCrossChannelForward(cuda_->cudnn(),
                                                 normDesc_,
                                                 CUDNN_LRN_CROSS_CHANNEL_DIM1,
                                                 &cuda_->one,
                                                 input_desc_,
                                                 input_->cuda(),
                                                 &cuda_->zero,
                                                 output_desc_,
                                                 output_->cuda()));

#if (DEBUG_CONV & 0x01)
    input_->print(  name_ + "::input", true, input_->n(), 28);
    output_->print( name_ + "::output", true);
#endif

    return output_;
}

Blob<float> *LRN::backward(Blob<float> *grad_input) {
    // initialize grad_output back-propagation space
    if (grad_input_ == nullptr || batch_size_ != grad_input->n()) {
        grad_output_ = grad_input;

        if (grad_input_ == nullptr)
            grad_input_ = new Blob<float>(input_->shape());
        else
            grad_input_->reset(input_->shape());
    }


    checkCudnnErrors(cudnnLRNCrossChannelBackward(cuda_->cudnn(),
                                                  normDesc_,
                                                  CUDNN_LRN_CROSS_CHANNEL_DIM1,
                                                  &cuda_->one,
                                                  output_desc_,
                                                  output_->cuda(),
                                                  output_desc_,
                                                  grad_output_->cuda(),
                                                  input_desc_,
                                                  input_->cuda(),
                                                  &cuda_->zero,
                                                  input_desc_,
                                                  grad_input_->cuda()));

    return grad_input_;
}


/****************************************************************
 * Dropout definition                      *
 ****************************************************************/

Dropout::Dropout(std::string name, float dropout) {
    name_ = name;
    dropout_ = dropout;

    checkCudnnErrors(cudnnCreateDropoutDescriptor(&dropoutDesc_));

}

Dropout::~Dropout() {
    cudnnDestroyDropoutDescriptor(dropoutDesc_);
    if (states_ != nullptr) cudaFree(states_);
    if (m_pReserve_ != nullptr) cudaFree(m_pReserve_);
}

Blob<float> *Dropout::forward(Blob<float> *input) {
    // initilaize input and output
    if (input_ == nullptr || batch_size_ != input->n()) {
        input_ = input;
        batch_size_ = input->n();
        input_desc_ = input_->tensor();

        if (output_ == nullptr)
            output_ = new Blob<float>(input->shape());
        else
            output_->reset(input->shape());
        output_desc_ = output_->tensor();

        checkCudnnErrors(cudnnDropoutGetStatesSize(cuda_->cudnn(), &stateSize_));
        if (states_ != nullptr) checkCudaErrors(cudaFree(states_));
        checkCudaErrors(cudaMalloc((void **) &states_, stateSize_));
        checkCudnnErrors(cudnnDropoutGetReserveSpaceSize(input_desc_, &reserveSize_));
        if (m_pReserve_ != nullptr) checkCudaErrors(cudaFree(m_pReserve_));
        checkCudaErrors(cudaMalloc((void **) &m_pReserve_, reserveSize_));


        checkCudnnErrors(cudnnSetDropoutDescriptor(dropoutDesc_,
                                                   cuda_->cudnn(),
                                                   dropout_,
                                                   states_,
                                                   stateSize_,
                                                   seed_));
    }

    checkCudnnErrors(cudnnDropoutForward(cuda_->cudnn(),
                                         dropoutDesc_,
                                         input_desc_,
                                         input_->cuda(),
                                         output_desc_,
                                         output_->cuda(),
                                         m_pReserve_,
                                         reserveSize_));
    return output_;
}

Blob<float> *Dropout::backward(Blob<float> *grad_input) {
    // initialize grad_output back-propagation space
    if (grad_input_ == nullptr || batch_size_ != grad_input->n()) {
        grad_output_ = grad_input;

        if (grad_input_ == nullptr)
            grad_input_ = new Blob<float>(input_->shape());
        else
            grad_input_->reset(input_->shape());
    }
    checkCudnnErrors(cudnnDropoutBackward(cuda_->cudnn(), dropoutDesc_,
                                          output_desc_, grad_output_->cuda(),
                                          input_desc_, grad_input_->cuda(),
                                          m_pReserve_, reserveSize_));

    return grad_input_;
}

/****************************************************************
 * FusedBatchNormalization definition                           *
 ****************************************************************/
FusedBatchNormalization::FusedBatchNormalization(std::string name, cudnnBatchNormMode_t mode) {
    name_ = name;
    mode_ = mode;

    checkCudnnErrors(cudnnCreateTensorDescriptor(&bnScaleBiasMeanVarDesc_));
}

FusedBatchNormalization::~FusedBatchNormalization() {
    cudnnDestroyTensorDescriptor(bnScaleBiasMeanVarDesc_);
}

Blob<float> *FusedBatchNormalization::forward(Blob<float> *input) {
    // initialize weights and biases
    if (weights_ == nullptr) {

        // initialize weight, bias
        size_ = input->c();
        weights_ = new Blob<float>(1, size_, 1, 1);
        biases_ = new Blob<float>(1, size_, 1, 1);
        weights_m_ = new Blob<float>(1, size_, 1, 1);
        weights_v_ = new Blob<float>(1, size_, 1, 1);
        biases_m_ = new Blob<float>(1, size_, 1, 1);
        biases_v_ = new Blob<float>(1, size_, 1, 1);
    }
    // initilaize input and output
    if (input_ == nullptr || batch_size_ != input->n()) {
        input_ = input;
        batch_size_ = input->n();
        input_desc_ = input_->tensor();

        if (output_ == nullptr)
            output_ = new Blob<float>(input->shape());
        else
            output_->reset(input->shape());

        output_desc_ = output_->tensor();

        cudaMalloc(&resultRunningMean_, sizeof(float) * size_);
        cudaMalloc(&resultRunningVariance_, sizeof(float) * size_);

        cudaMalloc(&resultSaveMean_, sizeof(float) * size_);
        cudaMalloc(&resultSaveInvVariance_, sizeof(float) * size_);

        checkCudnnErrors(cudnnDeriveBNTensorDescriptor(bnScaleBiasMeanVarDesc_, input_desc_, mode_));

        // initialize weights and biases
        if (load_pretrain_ && !freeze_) {
            if (load_parameter()) {
                std::cout << "error occurred.." << std::endl;
                exit(-1);
            }
        } else if (!freeze_) {
            init_weight_bias();
        } else {
            /* do nothing */
        }
    }

    //y = beta*y + alpha *[bnBias + (bnScale * (x-estimatedMean)/sqrt(epsilon + estimatedVariance)]

    checkCudnnErrors(
            cudnnBatchNormalizationForwardTraining(cuda_->cudnn(), mode_, &cuda_->one, &cuda_->zero, input_desc_,
                                                   input_->cuda(), output_desc_, output_->cuda(),
                                                   bnScaleBiasMeanVarDesc_, weights_->cuda(), biases_->cuda(),
                                                   cuda_->one, resultRunningMean_, resultRunningVariance_,
                                                   epison, resultSaveMean_, resultSaveInvVariance_));

#if (DEBUG_FBN & 0x01)
    std::cout << name_ << "[FORWARD]" << std::endl;
    input_->print(name_ + "::input", true, input_->n(), input_->h());
    weights_->print(name_ + "::weight", true, weights_->n(), weights_->c());
    biases_->print(name_ + "::bias", true, biases_->n(), biases_->c());
    output_->print(name_ + "::output", true, output_->n(), output_->h());
#endif

    return output_;
}

Blob<float> *FusedBatchNormalization::backward(Blob<float> *grad_input) {
    // initialize grad_output back-propagation space
    if (grad_input_ == nullptr || batch_size_ != grad_input->n()) {
        grad_output_ = grad_input;
        grad_weights_ = new Blob<float>(weights_->shape());
        grad_biases_ = new Blob<float>(biases_->shape());

        if (grad_input_ == nullptr)
            grad_input_ = new Blob<float>(input_->shape());
        else
            grad_input_->reset(input_->shape());
    }

    checkCudnnErrors(
            cudnnBatchNormalizationBackward(cuda_->cudnn(), mode_, &cuda_->one, &cuda_->zero, &cuda_->one, &cuda_->zero,
                                            input_desc_, input_->cuda(), output_desc_, grad_output_->cuda(),
                                            input_desc_, grad_input_->cuda(), bnScaleBiasMeanVarDesc_, weights_->cuda(),
                                            grad_weights_->cuda(), grad_biases_->cuda(), epison,
                                            resultSaveMean_, resultSaveInvVariance_));

#if (DEBUG_FBN & 0x02)
    std::cout << name_ << "[BACKWARD]" << std::endl;
    grad_output_->print(  name_ + "::gradients", true, grad_output_->n());
    grad_weights_->print(name_ + "::gfilter", true);
    grad_biases_->print( name_ + "::gbias", true);
    if (!gradient_stop_)
        grad_input_->print(  name_ + "::gdata", true);
#endif // DEBUG_FBN

    return grad_input_;
}
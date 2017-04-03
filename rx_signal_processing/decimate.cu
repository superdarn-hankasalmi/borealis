/*
Copyright 2017 SuperDARN Canada

See LICENSE for details

This file contains the CUDA code used to process the large amount of data
involved with radar receive side processing.
*/

#include <cuComplex.h> //cuComplex type and all cuCmulf/cuCaddf functions.
#include <iostream>
#include <stdint.h>

//This keeps the contained functions local to this file.
namespace {
  /**
   * @brief      Creates a new set of grid dimensions for a decimate CUDA kernel.
   *
   * @param[in]  num_samples   Number of input samples.
   * @param[in]  dm_rate       Decimation rate.
   * @param[in]  num_antennas  Number of antennas for which there are samples.
   *
   * @return     New grid dimensions for the kernel.
   */
  dim3 create_grid(uint32_t num_samples, uint32_t dm_rate, uint32_t num_antennas) // REVIEW #26 no more antennas
  {
    auto num_blocks_x = num_samples/dm_rate;
    auto num_blocks_y = num_antennas;
    auto num_blocks_z = 1;
    std::cout << "    Grid size: " << num_blocks_x << " x " << num_blocks_y << " x "
      << num_blocks_z << std::endl;
    dim3 dimGrid(num_blocks_x,num_blocks_y,num_blocks_z);

    return dimGrid;
  }

  /**
   * @brief      Creates a new set of block dimensions for a decimate CUDA kernel.
   *
   * @param[in]  num_taps_per_filter  Number of taps per filter.
   * @param[in]  num_freqs            Number of receive frequencies.
   *
   * @return     New block dimensions for the kernel.
   */
  dim3 create_block(uint32_t num_taps_per_filter, uint32_t num_freqs)
  {
    auto num_threads_x = num_taps_per_filter;
    auto num_threads_y = num_freqs;
    auto num_threads_z = 1;
    std::cout << "    Block size: " << num_threads_x << " x " << num_threads_y << " x "
      << num_threads_z << std::endl;
    dim3 dimBlock(num_threads_x,num_threads_y,num_threads_z);

    return dimBlock;
  }
}

/**
 * @brief      Overloads __shfl_down to handle cuComplex.
 *
 * @param[in]  var      cuComplex value to shuffle.
 * @param[in]  srcLane  Relative lane from within the warp that should shuffle its variable down.
 * @param[in]  width    Section of the warp to shuffle. Defaults to full warp size.
 *
 * @return     Shuffled cuComplex variable.
 *
 * __shfl can only shuffle 4 bytes at time. This overload utilizes a trick similar to the below
 * link in order to shuffle 8 byte values.
 * https://devblogs.nvidia.com/parallelforall/faster-parallel-reductions-kepler/
 * http://docs.nvidia.com/cuda/cuda-c-programming-guide/#warp-shuffle-functions
 */
__device__ inline cuComplex __shfl_down(cuComplex var, unsigned int srcLane, int width=32){
  float2 a = *reinterpret_cast<float2*>(&var);
  a.x = __shfl_down(a.x, srcLane, width);
  a.y = __shfl_down(a.y, srcLane, width);
  return *reinterpret_cast<cuComplex*>(&a);
}

/**
 * @brief      Performs a parallel reduction to sum a series of values together.
 *
 * @param      data        A pointer to a set of cuComplex data to reduce.
 * @param[in]  tap_offset  The offset into the data from which to pull values.
 *
 * @return     Final sum after reduction.
 *
 * NVIDIA supplies many versions of optimized parallel reduction. This is a slightly modified
 * version of reduction #5 from NVIDIA examples.
 * /usr/local/cuda/samples/6_Advanced/reduction
 */
__device__ cuComplex parallel_reduce(cuComplex* data, uint32_t tap_offset) {
  auto filter_tap_num = threadIdx.x;
  auto num_filter_taps = blockDim.x;
  cuComplex total_sum = data[tap_offset];

  if ((num_filter_taps >= 1024) && (filter_tap_num < 512))
  {
    total_sum = cuCaddf(total_sum,data[tap_offset  + 512]);
    data[tap_offset] = total_sum;
  }

  __syncthreads();

  if ((num_filter_taps >= 512) && (filter_tap_num < 256))
  {
    total_sum = cuCaddf(total_sum,data[tap_offset  + 256]);
    data[tap_offset] = total_sum;
  }

  __syncthreads();

  if ((num_filter_taps >= 256) && (filter_tap_num < 128))
  {
    total_sum = cuCaddf(total_sum, data[tap_offset + 128]);
    data[tap_offset] = total_sum;
  }

   __syncthreads();

  if ((num_filter_taps >= 128) && (filter_tap_num <  64))
  {
    total_sum = cuCaddf(total_sum, data[tap_offset  +  64]);
    data[tap_offset] = total_sum;
  }

  __syncthreads();

  if ( filter_tap_num < 32 )
  {
    // Fetch final intermediate sum from 2nd warp
    if (num_filter_taps >=  64) total_sum = cuCaddf(total_sum, data[tap_offset + 32]);
    // Reduce final warp using shuffle
    // http://docs.nvidia.com/cuda/cuda-c-programming-guide/#built-in-variables
    // __shfl_down is used an optimization in the final warp to simulatenously move
    // values from upper threads to lower threads without needing __syncthreads().
    for (int offset = warpSize/2; offset > 0; offset /= 2)
    {
      total_sum = cuCaddf(total_sum,__shfl_down(total_sum, offset));
    }
  }

  return total_sum;
}

/**
 * @brief      Performs decimation on a set of samples if the total number of filter taps for all
 *             filters is less than 1024.
 *
 * @param[in]  original_samples     A pointer to original input samples from each antenna to
 *                                  decimate.
 * @param[in]  decimated_samples    A pointer to a buffer to place output samples for each
 *                                  frequency after decimation.
 * @param[in]  filter_taps          A pointer to one or more filters needed for each frequency.
 * @param[in]  dm_rate              Decimation rate.
 * @param[in]  samples_per_antenna  The number of samples per antenna in the original set of
 *                                  samples.
 *
 * This function performs a parallel version of filtering+downsampling on the GPU to be able
 * process data in realtime. This algorithm will use 1 GPU thread per filter tap if there are less
 * than 1024 taps for all filters combined. Only works with power of two length filters, or a
 * filter that is zero padded to a power of two in length.
 *
 *   gridDim.x - Total number of output samples there will be after decimation.
 *   gridDim.y - Total number of antennas.
 *
 *   blockIdx.x - Decimated output sample index.
 *   blockIdx.y - Antenna index.
 *
 *   blockDim.x - Number of filter taps in each filter.
 *   blockDim.y - Total number of filters. Corresponds to total receive frequencies.
 *
 *   threadIdx.x - Filter tap index.
 *   threadIdx.y - Filter index.
 */
__global__ void decimate1024(cuComplex* original_samples,
  cuComplex* decimated_samples,
  cuComplex* filter_taps, uint32_t dm_rate,
  uint32_t samples_per_antenna) {

  // Since number of filter taps is calculated at runtime and we do not want to hardcode
  // values, the shared memory can be dynamically initialized at invocation of the kernel.
  // http://docs.nvidia.com/cuda/cuda-c-programming-guide/index.html#shared

  extern __shared__ cuComplex filter_products[];

  auto antenna_num = blockIdx.y;
  auto antenna_offset = antenna_num * samples_per_antenna;

  auto dec_sample_num = blockIdx.x;
  auto dec_sample_offset = dec_sample_num * dm_rate;

  auto tap_offset = threadIdx.y * blockDim.x + threadIdx.x;

  // If an offset should extend past the length of samples per antenna
  // then zeroes are used as to not segfault or run into the next buffer.
  // output samples using these will be discarded as to not introduce edge effects
  cuComplex sample;
  if ((dec_sample_offset + threadIdx.x) >= samples_per_antenna) {
    sample = make_cuComplex(0.0f,0.0f);
  }
  else {
    auto final_offset = antenna_offset + dec_sample_offset + threadIdx.x;
    sample = original_samples[final_offset];
  }


  filter_products[tap_offset] = cuCmulf(sample,filter_taps[tap_offset]);
  // Synchronizes all threads in a block, meaning 1 output sample per rx freq
  // is ready to be calculated with the parallel reduce
  __syncthreads();

  auto calculated_output_sample = parallel_reduce(filter_products, tap_offset);

  // When decimating, we go from one set of samples for each antenna
  // to multiple sets of reduced samples for each frequency. Output samples are
  // grouped by frequency with all samples for each antenna following each other
  // before samples of another frequency start.
  if (threadIdx.x == 0) {
    antenna_offset = antenna_num * samples_per_antenna/dm_rate; // REVIEW #13 gridDimx is already samples_per_antenna/dm_rate, use it instead
                                  // REPLY it is, yet I've been trying to avoid direct use of CUDA builtin types since it not obvious what they mean
    auto total_antennas = gridDim.y;
    auto freq_offset = threadIdx.y * gridDim.x * total_antennas;
    auto total_offset = freq_offset + antenna_offset + dec_sample_num;
    decimated_samples[total_offset] = calculated_output_sample;
  }
}

/**
 * @brief      Performs decimation on a set of samples if the total number of filter taps for all
 *             filters is less than 2048.
 *
 * @param[in]  original_samples     A pointer to original input samples from each antenna to
 *                                  decimate.
 * @param[in]  decimated_samples    A pointer to a buffer to place output samples for each frequency
 *                                  after decimation.
 * @param[in]  filter_taps          A pointer to one or more filters needed for each frequency.
 * @param[in]  dm_rate              Decimation rate.
 * @param[in]  samples_per_antenna  The number of samples per antenna in the original set of
 *                                  samples.
 *
 * This function performs a parallel version of filtering+downsampling on the GPU to be able process
 * data in realtime. This algorithm will use 1 GPU thread to process two filter taps if there are
 * less than 2048 taps for all filters combined. Intended to be used if there are more than 1024
 * total threads, as that is the max block size possible for CUDA. Only works with power of two
 * length filters, or a filter that is zero padded to a power of two in length.
 *
 *   gridDim.x - Total number of output samples there will be after decimation.
 *   gridDim.y - Total number of antennas.
 *
 *   blockIdx.x - Decimated output sample index.
 *   blockIdx.y - Antenna index.
 *
 *   blockDim.x - Number of filter taps in each filter.
 *   blockDim.y - Total number of filters. Corresponds to total receive frequencies.
 *
 *   threadIdx.x - Filter tap index.
 *   threadIdx.y - Filter index.
 */
__global__ void decimate2048(cuComplex* original_samples,
  cuComplex* decimated_samples,
  cuComplex* filter_taps, uint32_t dm_rate,
  uint32_t samples_per_antenna)
{

  // Since number of filter taps is calculated at runtime and we do not want to hardcode
  // values, the shared memory can be dynamically initialized at invocation of the kernel.
  // http://docs.nvidia.com/cuda/cuda-c-programming-guide/index.html#shared

  extern __shared__ cuComplex filter_products[];

  auto antenna_num = blockIdx.y;
  auto antenna_offset = antenna_num * samples_per_antenna;

  auto dec_sample_num = blockIdx.x;
  auto dec_sample_offset = dec_sample_num * dm_rate;

  auto tap_offset = threadIdx.y * blockDim.x + 2 * threadIdx.x;

  cuComplex sample_1;
  cuComplex sample_2;
  // If an offset should extend past the length of samples per antenna
  // then zeroes are used as to not segfault or run into the next buffer.
  // output samples using these will be discarded as to not introduce edge effects
  if ((dec_sample_offset + 2 * threadIdx.x) >= samples_per_antenna) {
    // the case both samples are out of bounds
    sample_1 = make_cuComplex(0.0,0.0);
    sample_2 = make_cuComplex(0.0,0.0);
  }
  else if ((dec_sample_offset + 2 * threadIdx.x) >= samples_per_antenna - 1) {
    // the case only one sample would be out of bounds
    auto final_offset = antenna_offset + dec_sample_offset + 2*threadIdx.x;
    sample_1 = original_samples[final_offset];
    sample_2 = make_cuComplex(0.0,0.0);
  }
  else {
    auto final_offset = antenna_offset + dec_sample_offset + 2*threadIdx.x;
    sample_1 = original_samples[final_offset];
    sample_2 = original_samples[final_offset+1];
  }


  filter_products[tap_offset] = cuCmulf(sample_1,filter_taps[tap_offset]);
  filter_products[tap_offset+1] = cuCmulf(sample_2, filter_taps[tap_offset+1]);

  // An additional add must happen first in this case since the parallel reduce will only
  // run on even data indices.
  filter_products[tap_offset] = cuCaddf(filter_products[tap_offset],filter_products[tap_offset+1]);
  __syncthreads();

  auto calculated_output_sample = parallel_reduce(filter_products, tap_offset);

  // When decimating, we go from one set of samples for each antenna
  // to multiple sets of reduced samples for each frequency. Output samples are
  // grouped by frequency with all samples for each antenna following each other
  // before samples of another frequency start.
  if (threadIdx.x == 0) {
    antenna_offset = antenna_num * samples_per_antenna/dm_rate; // REVIEW #13 gridDimx is already samples_per_antenna/dm_rate, use it instead
                                  // REPLY it is, yet I've been trying to avoid direct use of CUDA builtin types since it not obvious what they mean
    auto total_antennas = gridDim.y;
    auto freq_offset = threadIdx.y * gridDim.x * total_antennas;
    auto total_offset = freq_offset + antenna_offset + dec_sample_num;
    decimated_samples[total_offset] = calculated_output_sample;
  }
}

/**
 * @brief      This function wraps the decimate1024 kernel so that it can be called from another
 *             file.
 *
 * @param[in]  original_samples     A pointer to original input samples from each antenna to
 *                                  decimate.
 * @param[in]  decimated_samples    A pointer to a buffer to place output samples for each frequency
 *                                  after decimation.
 * @param[in]  filter_taps          A pointer to one or more filters needed for each frequency.
 * @param[in]  dm_rate              Decimation rate.
 * @param[in]  samples_per_antenna  The number of samples per antenna in the original set of
 *                                  samples.
 * @param[in]  num_taps_per_filter  Number of taps per filter.
 * @param[in]  num_freqs            Number of receive frequencies.
 * @param[in]  num_antennas         Number of antennas for which there are samples.
 * @param[in]  stream               CUDA stream with which to associate the invocation of the
 *                                  kernel.
 */
void decimate1024_wrapper(cuComplex* original_samples,
  cuComplex* decimated_samples,
  cuComplex* filter_taps, uint32_t dm_rate,
  uint32_t samples_per_antenna, uint32_t num_taps_per_filter, uint32_t num_freqs,
  uint32_t num_antennas, cudaStream_t stream) {

  //Allocate shared memory on device for all filter taps.
  auto shr_mem_taps = num_freqs * num_taps_per_filter * sizeof(cuComplex);
  std::cout << "    Number of shared memory bytes: "<< shr_mem_taps << std::endl;

  auto dimGrid = create_grid(samples_per_antenna, dm_rate, num_antennas);
  auto dimBlock = create_block(num_taps_per_filter,num_freqs);
  decimate1024<<<dimGrid,dimBlock,shr_mem_taps,stream>>>(original_samples, decimated_samples,
        filter_taps, dm_rate, samples_per_antenna);

}

/**
 * @brief      This function wraps the decimate2048 kernel so that it can be called from another
 *             file.
 *
 * @param[in]  original_samples     A pointer to original input samples from each antenna to
 *                                  decimate.
 * @param[in]  decimated_samples    A pointer to a buffer to place output samples for each frequency
 *                                  after decimation.
 * @param[in]  filter_taps          A pointer to one or more filters needed for each frequency.
 * @param[in]  dm_rate              Decimation rate.
 * @param[in]  samples_per_antenna  The number of samples per antenna in the original set of
 *                                  samples.
 * @param[in]  num_taps_per_filter  Number of taps per filter.
 * @param[in]  num_freqs            Number of receive frequencies.
 * @param[in]  num_antennas         Number of antennas for which there are samples.
 * @param[in]  stream               CUDA stream with which to associate the invocation of the
 *                                  kernel.
 */
void decimate2048_wrapper(cuComplex* original_samples,
  cuComplex* decimated_samples,
  cuComplex* filter_taps, uint32_t dm_rate,
  uint32_t samples_per_antenna, uint32_t num_taps_per_filter, uint32_t num_freqs,
  uint32_t num_antennas, cudaStream_t stream) {

  //Allocate shared memory on device for all filter taps.
  auto shr_mem_taps = num_freqs * num_taps_per_filter * sizeof(cuComplex);
  std::cout << "    Number of shared memory bytes: "<< shr_mem_taps << std::endl;

  auto dimGrid = create_grid(samples_per_antenna, dm_rate, num_antennas);
  auto dimBlock = create_block(num_taps_per_filter/2, num_freqs);
  decimate2048<<<dimGrid,dimBlock,shr_mem_taps,stream>>>(original_samples, decimated_samples,
    filter_taps, dm_rate, samples_per_antenna);
}
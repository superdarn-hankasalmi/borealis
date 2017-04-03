/*

Copyright 2017 SuperDARN Canada

See LICENSE for details

  \file dsp.cu
  This file contains the implemenation for the all the needed GPU DSP work.
*/

#include "dsp.hpp"
#include "utils/protobuf/sigprocpacket.pb.h"
#include <iostream>
#include <fstream>
#include <string>
#include <sstream>
#include <cuComplex.h>
#include <chrono>
#include <thread>

//TODO(keith): decide on handing gpu errors
//TODO(keith): potentially add multigpu support

//This keep postprocess local to this file.
namespace {
  /**
   * @brief      Performs the host side postprocessing after data is transfered back from device.
   *
   * @param[in]      dp    A pointer to a DSPCore object that has completed its GPU work.
   */
  void postprocess(DSPCore *dp)
  {

    dp->stop_timing();
    dp->send_timing();
    std::cout << "Cuda kernel timing: " << dp->get_decimate_timing()
      << "ms" <<std::endl;
    std::cout << "Complete process timing: " << dp->get_total_timing()
      << "ms" <<std::endl;

    dp->clear_device_and_destroy();
    //TODO(keith): add copy to host and final process details

    delete dp;
  }
}

extern void decimate1024_wrapper(cuComplex* original_samples,
  cuComplex* decimated_samples,
  cuComplex* filter_taps, uint32_t dm_rate,
  uint32_t samples_per_antenna, uint32_t num_taps_per_filter, uint32_t num_freqs,
  uint32_t num_antennas, cudaStream_t stream);

extern void decimate2048_wrapper(cuComplex* original_samples,
  cuComplex* decimated_samples,
  cuComplex* filter_taps, uint32_t dm_rate,
  uint32_t samples_per_antenna, uint32_t num_taps_per_filter, uint32_t num_freqs,
  uint32_t num_antennas, cudaStream_t stream);


/**
 * @brief      Gets the properties of each GPU in the system.
 *
 * @return     The gpu properties.
 */
std::vector<cudaDeviceProp> get_gpu_properties()
{
  std::vector<cudaDeviceProp> gpu_properties;
  int num_devices = 0;

  gpuErrchk(cudaGetDeviceCount(&num_devices));

  for(int i=0; i< num_devices; i++) {
      cudaDeviceProp properties;
      gpuErrchk(cudaGetDeviceProperties(&properties, i));
      gpu_properties.push_back(properties);
  }

  return gpu_properties;
}

/**
 * @brief      Prints the properties of each cudaDeviceProp in the vector.
 *
 * @param[in]  gpu_properties  A vector of cudaDeviceProp structs.
 */
void print_gpu_properties(std::vector<cudaDeviceProp> gpu_properties) {
  for(auto i : gpu_properties) {
    std::cout << "Device name: " << i.name << std::endl;
    std::cout << "  Max grid size x: " << i.maxGridSize[0] << std::endl;
    std::cout << "  Max grid size y: " << i.maxGridSize[1] << std::endl;
    std::cout << "  Max grid size z: " << i.maxGridSize[2] << std::endl;
    std::cout << "  Max threads per block: " << i.maxThreadsPerBlock
      << std::endl;
    std::cout << "  Max size of block dimension x: " << i.maxThreadsDim[0]
      << std::endl;
    std::cout << "  Max size of block dimension y: " << i.maxThreadsDim[1]
      << std::endl;
    std::cout << "  Max size of block dimension z: " << i.maxThreadsDim[2]
      << std::endl;
    std::cout << "  Memory Clock Rate (GHz): " << i.memoryClockRate/1e6
      << std::endl;
    std::cout << "  Memory Bus Width (bits): " << i.memoryBusWidth
      << std::endl;
    std::cout << "  Peak Memory Bandwidth (GB/s): " <<
       2.0*i.memoryClockRate*(i.memoryBusWidth/8)/1.0e6 << std::endl; // REVIEW #29 magic calculation with magic numbers?
    std::cout << "  Max shared memory per block: " << i.sharedMemPerBlock
      << std::endl;
    std::cout << "  Warpsize: " << i.warpSize << std::endl;
  }
}





/**
  \brief Initializes the parameters needed in order to do asynchronous DSP processing.
  \param ack_s A pointer to the socket used for acknowledging when the transfer of RF samples
  to the device is completed.
  \param timing_s A pointer to the socket used for reporting GPU kernel timing.
  \param sq_num The pulse sequence number for which will be acknowledged.
  \param shr_mem_name The char string used to open a section of shared memory with RF samples.

  The constructor creates a new CUDA stream and initializes the timing events. It then opens
  the shared memory with the received RF samples for a pulse sequence.

*/

/**
 * @brief      Initializes the parameters needed in order to do asynchronous DSP processing.
 *
 * @param      ack_s         A pointer to the socket used for acknowledging when the transfer of RF
 *                           samples.
 * @param[in]  timing_s      A pointer to the socket used for reporting GPU kernel timing.
 * @param[in]  sq_num        The pulse sequence number for which will be acknowledged.
 * @param[in]  shr_mem_name  The char string used to open a section of shared memory with RF
 *                           samples.
 *
 * The constructor creates a new CUDA stream and initializes the timing events. It then opens
 * the shared memory with the received RF samples for a pulse sequence.
 */
DSPCore::DSPCore(zmq::socket_t *ack_s, zmq::socket_t *timing_s,
                    uint32_t sq_num, const char* shr_mem_name) //TODO(Keith): revisit str
{

  sequence_num = sq_num;
  ack_socket = ack_s;
  timing_socket = timing_s;

  gpuErrchk(cudaStreamCreate(&stream)); // REVIEW #1 explain what's going on here
                      // REPLY this can maybe be a link to the programming guide and maybe some explaination in the written document
  gpuErrchk(cudaEventCreate(&initial_start));
  gpuErrchk(cudaEventCreate(&kernel_start));
  gpuErrchk(cudaEventCreate(&stop));
  gpuErrchk(cudaEventRecord(initial_start, stream));

  shr_mem = new SharedMemoryHandler(shr_mem_name);
  shr_mem->open_shr_mem();

}

/**
 * @brief      Allocates device memory for the RF samples and then copies them to device.
 *
 * @param[in]  total_samples  Total number of samples to copy.
 */
void DSPCore::allocate_and_copy_rf_samples(uint32_t total_samples)
{
  rf_samples_size = total_samples * sizeof(cuComplex);
  gpuErrchk(cudaMalloc(&rf_samples_d, rf_samples_size));
  gpuErrchk(cudaMemcpyAsync(rf_samples_d,shr_mem->get_shrmem_addr(), rf_samples_size, cudaMemcpyHostToDevice, stream));

}

/**
 * @brief      Allocates device memory for the first stage filters and then copies them to the
 *             device.
 *
 * @param[in]  taps        A pointer to the first stage filter taps.
 * @param[in]  total_taps  The total number of taps for all filters.
 */
void DSPCore::allocate_and_copy_first_stage_filters(void *taps, uint32_t total_taps)
{
  first_stage_bp_filters_size = total_taps * sizeof(cuComplex);
  gpuErrchk(cudaMalloc(&first_stage_bp_filters_d, first_stage_bp_filters_size));
  gpuErrchk(cudaMemcpyAsync(first_stage_bp_filters_d, taps,
        first_stage_bp_filters_size, cudaMemcpyHostToDevice, stream));
}

/**
 * @brief      Allocates device memory for the second stage filters and then copies them to the
 *             device.
 *
 * @param[in]  taps        A pointer to the second stage filter taps.
 * @param[in]  total_taps  The total number of taps for all filters.
 */
void DSPCore::allocate_and_copy_second_stage_filter(void *taps, uint32_t total_taps)
{
  second_stage_filters_size = total_taps * sizeof(cuComplex);
  gpuErrchk(cudaMalloc(&second_stage_filters_d, second_stage_filters_size));
  gpuErrchk(cudaMemcpyAsync(second_stage_filters_d, taps,
         second_stage_filters_size, cudaMemcpyHostToDevice, stream));
}

/**
 * @brief      Allocates device memory for the third stage filters and then copies them to the
 *             device.
 *
 * @param[in]  taps        A pointer to the third stage filters.
 * @param[in]  total_taps  The total number of taps for all filters.
 */
void DSPCore::allocate_and_copy_third_stage_filter(void *taps, uint32_t total_taps)
{
  third_stage_filters_size = total_taps * sizeof(cuComplex);
  gpuErrchk(cudaMalloc(&third_stage_filters_d, third_stage_filters_size));
  gpuErrchk(cudaMemcpyAsync(third_stage_filters_d, taps,
        third_stage_filters_size, cudaMemcpyHostToDevice, stream));
}

/**
 * @brief      Allocates device memory for the output of the first stage filters.
 *
 * @param[in]  num_first_stage_output_samples  The total number of output samples from first
 *                                             stage.
 */
void DSPCore::allocate_first_stage_output(uint32_t num_first_stage_output_samples)
{
  first_stage_output_size = num_first_stage_output_samples * sizeof(cuComplex);
  gpuErrchk(cudaMalloc(&first_stage_output_d, first_stage_output_size));
}

/**
 * @brief      Allocates device memory for the output of the second stage filters.
 *
 * @param[in]  num_second_stage_output_samples  The total number of output samples from second
 *             stage.
 */
void DSPCore::allocate_second_stage_output(uint32_t num_second_stage_output_samples)
{
  second_stage_output_size = num_second_stage_output_samples * sizeof(cuComplex);
  gpuErrchk(cudaMalloc(&second_stage_output_d, second_stage_output_size));
}

/**
 * @brief      Allocates device memory for the output of the third stage filters.
 *
 * @param[in]  num_third_stage_output_samples  The total number of output samples from third
 *                                             stage.
 */
void DSPCore::allocate_third_stage_output(uint32_t num_third_stage_output_samples)
{
  third_stage_output_size = num_third_stage_output_samples * sizeof(cuComplex);
  gpuErrchk(cudaMalloc(&third_stage_output_d, third_stage_output_size));
}

/**
 * @brief      Allocates host memory for final decimated samples and copies from device to host.
 *
 * @param[in]  num_host_samples  Number of host samples to copy back from device.
 */
void DSPCore::allocate_and_copy_host_output(uint32_t num_host_samples)
{
  host_output_size = num_host_samples * sizeof(cuComplex);
  gpuErrchk(cudaHostAlloc(&host_output_h, host_output_size, cudaHostAllocDefault));
  gpuErrchk(cudaMemcpyAsync(host_output_h, third_stage_output_d,
        host_output_size, cudaMemcpyDeviceToHost,stream));
}

//TODO(keith): dont think this is needed
void DSPCore::copy_output_to_host()
{
  gpuErrchk(cudaMemcpy(host_output_h, third_stage_output_d,
         host_output_size, cudaMemcpyDeviceToHost));
}

/**
 * @brief      Frees all associated pointers, events, and streams. Removes and deletes shared
 *             memory.
 */
void DSPCore::clear_device_and_destroy() //TODO(keith): rework into destructor?
{
  gpuErrchk(cudaFree(rf_samples_d));
  gpuErrchk(cudaFree(first_stage_bp_filters_d));
  gpuErrchk(cudaFree(second_stage_filters_d));
  gpuErrchk(cudaFree(third_stage_filters_d));
  gpuErrchk(cudaFree(first_stage_output_d));
  gpuErrchk(cudaFree(second_stage_output_d));
  gpuErrchk(cudaFree(third_stage_output_d));
  gpuErrchk(cudaFreeHost(host_output_h));
  gpuErrchk(cudaEventDestroy(initial_start));
  gpuErrchk(cudaEventDestroy(kernel_start));
  gpuErrchk(cudaEventDestroy(stop));
  gpuErrchk(cudaStreamDestroy(stream));

  shr_mem->remove_shr_mem();
  delete shr_mem;

}

/**
 * @brief      Stops the timers that the constructor starts.
 */
void DSPCore::stop_timing()
{
  gpuErrchk(cudaEventRecord(stop, stream));
  gpuErrchk(cudaEventSynchronize(stop));

  gpuErrchk(cudaEventElapsedTime(&total_process_timing_ms, initial_start, stop));
  gpuErrchk(cudaEventElapsedTime(&decimate_kernel_timing_ms, kernel_start, stop));

}

/**
 * @brief      Sends the GPU kernel timing to the radar control.
 *
 * The timing here is used as a rate limiter, so that the GPU doesn't become backlogged with data.
 * If the GPU is overburdened, this will result in less averages, but the system wont crash.
 */
void DSPCore::send_timing()
{
  sigprocpacket::SigProcPacket sp;
  sp.set_kerneltime(decimate_kernel_timing_ms);
  sp.set_sequence_num(sequence_num);

  std::string s_msg_str;
  sp.SerializeToString(&s_msg_str);
  zmq::message_t s_msg(s_msg_str.size());
  memcpy ((void *) s_msg.data (), s_msg_str.c_str(), s_msg_str.size());

  timing_socket->send(s_msg);
  std::cout << "Sent timing after processing" << std::endl;

}

/**
 * @brief      Spawns the postprocessing work after all work in the CUDA stream is completed.
 *
 * @param[in]  stream           CUDA stream this callback is associated with.
 * @param[in]  status           Error status of CUDA work in the stream.
 * @param[in]  processing_data  A pointer to the DSPCore associated with this CUDA stream.
 *
 * The callback itself cannot call anything CUDA related as it may deadlock. It can, however
 * spawn a new thread and then exit gracefully, allowing the thread to do the work.
 */
void CUDART_CB DSPCore::cuda_postprocessing_callback(cudaStream_t stream, cudaError_t status,
                            void *processing_data)
{
  gpuErrchk(status);
  std::thread start_pp(postprocess,static_cast<DSPCore*>(processing_data));
  start_pp.detach();
}

/**
 * @brief      Sends the acknowledgement to the radar control that the RF samples have been
 *             transfered.
 *
 * RF samples of one pulse sequence can be transfered asynchonously while samples of another are
 * being processed. This means that it is possible to start running a new pulse sequence in the
 * driver as soon as the samples are copied. The asynchronous nature means only timing constraint
 * is the time needed to run the GPU kernels for decimation.
 */
void DSPCore::send_ack()
{
  sigprocpacket::SigProcPacket sp;
  sp.set_sequence_num(sequence_num);

  std::string s_msg_str;
  sp.SerializeToString(&s_msg_str);
  zmq::message_t s_msg(s_msg_str.size());
  memcpy ((void *) s_msg.data (), s_msg_str.c_str(), s_msg_str.size());
  ack_socket->send(s_msg);
  std::cout << "Sent ack after copy" << std::endl;
}

/**
 * @brief      Starts the timing before the GPU kernels execute.
 */
void DSPCore::start_decimate_timing()
{
  gpuErrchk(cudaEventRecord(kernel_start, stream));
}

/**
 * @brief      Sends an acknowledgement to the radar control and starts the timing after the
 *             RF samples have been copied.
 *
 * @param[in]  dp    A pointer to a DSPCore object.
 */
void initial_memcpy_callback_handler(DSPCore *dp)
{
  dp->send_ack();
  dp->start_decimate_timing();
}

/**
 * @brief      Spawns the thread to handle the work after the RF samples have been copied.
 *
 * @param[in]  stream           CUDA stream this callback is associated with.
 * @param[in]  status           Error status of CUDA work in the stream.
 * @param[in]  processing_data  A pointer to the DSPCore associated with this CUDA stream.
 */
void CUDART_CB DSPCore::initial_memcpy_callback(cudaStream_t stream, cudaError_t status,
                        void *processing_data)
{
  gpuErrchk(status);
  std::thread start_imc(initial_memcpy_callback_handler,
              static_cast<DSPCore*>(processing_data));
  start_imc.join();

}

/**
 * @brief      Selects which decimate kernel to run.
 *
 * @param[in]  original_samples     A pointer to original input samples from each antenna to
 *                                  decimate.
 * @param[in]  decimated_samples    A pointer to a buffer to place output samples for each
 *                                  frequency after decimation.
 * @param[in]  filter_taps          A pointer to one or more filters needed for each frequency.
 * @param[in]  dm_rate              Decimation rate.
 * @param[in]  samples_per_antenna  The number of samples per antenna in the original set of
 *                                  samples.
 * @param[in]  num_taps_per_filter  Number of taps per filter.
 * @param[in]  num_freqs            Number of receive frequencies.
 * @param[in]  num_antennas         Number of antennas for which there are samples.
 * @param[in]  output_msg           A simple character string that can be used to debug or
 *                                  distiguish different stages.
 *
 * Based off the total number of filter taps, this function will choose what decimate kernel to
 * use.
 */
void DSPCore::call_decimate(cuComplex* original_samples,
  cuComplex* decimated_samples,
  cuComplex* filter_taps, uint32_t dm_rate,
  uint32_t samples_per_antenna, uint32_t num_taps_per_filter, uint32_t num_freqs,
  uint32_t num_antennas, const char *output_msg) {

  std::cout << output_msg << std::endl;

  auto gpu_properties = get_gpu_properties();


  //For now we have a kernel that will process 2 samples per thread if need be
  if (num_taps_per_filter * num_freqs > 2 * gpu_properties[0].maxThreadsPerBlock) {
    //TODO(Keith) : handle error
  }
  else if (num_taps_per_filter * num_freqs > gpu_properties[0].maxThreadsPerBlock) {
    decimate2048_wrapper(original_samples, decimated_samples, filter_taps,  dm_rate,
      samples_per_antenna, num_taps_per_filter, num_freqs, num_antennas, stream);
  }
  else {
    decimate1024_wrapper(original_samples, decimated_samples, filter_taps,  dm_rate,
      samples_per_antenna, num_taps_per_filter, num_freqs, num_antennas, stream);
  }
  // This is to detect invalid launch parameters.
  gpuErrchk(cudaPeekAtLastError());

}

/**
 * @brief      Gets the device pointer to the RF samples.
 *
 * @return     The RF samples device pointer.
 */
cuComplex* DSPCore::get_rf_samples_p(){
  return rf_samples_d;
}

/**
 * @brief      Gets the device pointer to the first stage bandpass filters.
 *
 * @return     The first stage bandpass filters device pointer.
 */
cuComplex* DSPCore::get_first_stage_bp_filters_p(){
  return first_stage_bp_filters_d;
}

/**
 * @brief      Gets the device pointer to the second stage filters.
 *
 * @return     The second stage filters device pointer.
 */
cuComplex* DSPCore::get_second_stage_filter_p(){
  return second_stage_filters_d;
}

/**
 * @brief      Gets the device pointer to the third stage filters.
 *
 * @return     The third stage filters device pointer.
 */
cuComplex* DSPCore::get_third_stage_filter_p(){
  return third_stage_filters_d;
}

/**
 * @brief      Gets the device pointer to output of the first stage decimation.
 *
 * @return     The first stage output device pointer.
 */
cuComplex* DSPCore::get_first_stage_output_p(){
  return first_stage_output_d;
}

/**
 * @brief      Gets the device pointer to output of the second stage decimation.
 *
 * @return     The second stage output device pointer.
 */
cuComplex* DSPCore::get_second_stage_output_p(){
  return second_stage_filters_d;
}

/**
 * @brief      Gets the device pointer to output of the third stage decimation.
 *
 * @return     The third stage output device pointer.
 */
cuComplex* DSPCore::get_third_stage_output_p(){
  return third_stage_filters_d;
}

/**
 * @brief      Gets the CUDA stream this DSPCore's work is associated to.
 *
 * @return     The CUDA stream.
 */
cudaStream_t DSPCore::get_cuda_stream(){
  return stream;
}

/**
 * @brief      Gets the total GPU process timing in milliseconds.
 *
 * @return     The total process timing.
 */
float DSPCore::get_total_timing()
{
  return total_process_timing_ms;
}

/**
 * @brief      Gets the total decimation timing in milliseconds.
 *
 * @return     The decimation timing.
 */
float DSPCore::get_decimate_timing()
{
  return decimate_kernel_timing_ms;
}



#include <zmq.hpp>
#include <thread>
#include <unistd.h>
#include <iostream>
#include <complex>
#include "utils/protobuf/driverpacket.pb.h"
#include "utils/driver_options/driveroptions.hpp"


std::vector<std::complex<float>> make_pulse(DriverOptions &driver_options){
    auto amp = 1.0/sqrt(2.0);
    auto pulse_len = 300.0 * 10e-6;
    auto tx_rate = driver_options.get_tx_rate();
    auto num_samps_per_antenna = tx_rate * pulse_len;
    std::vector<double> tx_freqs = {1e6};

    auto default_v = std::complex<float>(0.0,0.0);
    std::vector<std::complex<float>> samples(num_samps_per_antenna,default_v);


    for (auto j=0; j< num_samps_per_antenna; j++) {
        auto nco_point = std::complex<float>(0.0,0.0);

        for (auto freq : tx_freqs) {
          auto sampling_freq = 2 * M_PI * freq/tx_rate;

          auto radians = fmod(sampling_freq * j, 2 * M_PI);
          auto I = amp * cos(radians);
          auto Q = amp * sin(radians);

          nco_point += std::complex<float>(I,Q);
        }
        samples[j] = nco_point;
    }

      auto ramp_size = int(10e-6 * tx_rate);

      for (auto j=0; j<ramp_size; j++){
        auto a = ((j+1)*1.0)/ramp_size;
        samples[j] *= std::complex<float>(a,0);
      }

      for (auto j=num_samps_per_antenna-1;j>num_samps_per_antenna-1-ramp_size;j--){
        auto a = ((j+1)*1.0)/ramp_size;
        samples[j] *= std::complex<float>(a,0);
      }


    return samples;
}

int main(int argc, char *argv[]){

    DriverOptions driver_options;

    driverpacket::DriverPacket dp;
    zmq::context_t context(1);
    zmq::socket_t socket(context, ZMQ_PAIR);
    socket.connect(driver_options.get_radar_control_to_driver_address());


    auto pulse_samples = make_pulse(driver_options);
    for (int j=0; j<driver_options.get_main_antenna_count(); j++){
        dp.add_channels(j);
        auto samples = dp.add_channel_samples();

        for (auto &sm : pulse_samples){
            samples->add_real(sm.real());
            samples->add_imag(sm.imag());
        }
    }

    bool SOB, EOB = false;
    std::vector<int> pulse_seq = {0,9,12,20,22,26,27};

    auto first_time = true;
    while (1){
        for (auto &pulse : pulse_seq){
            std::chrono::steady_clock::time_point begin = std::chrono::steady_clock::now();

            if (pulse == pulse_seq.front()){
                SOB = true;
            }
            else{
                SOB = false;
            }

            if (pulse == pulse_seq.back()){
                EOB = true;
            }
            else{
                EOB = false;
            }
            std::cout << SOB << " " << EOB <<std::endl;
            dp.set_sob(SOB);
            dp.set_eob(EOB);
            dp.set_txrate(driver_options.get_tx_rate());
            dp.set_timetosendsamples(pulse * 1500);
            dp.set_txcenterfreq(12e6);
            dp.set_rxcenterfreq(14e6);
            dp.set_numberofreceivesamples(1000000);

            std::string msg_str;
            dp.SerializeToString(&msg_str);
            zmq::message_t request (msg_str.size());
            memcpy ((void *) request.data (), msg_str.c_str(), msg_str.size());
            std::chrono::steady_clock::time_point end= std::chrono::steady_clock::now();
            std::cout << "Time difference to serialize(us) = " << std::chrono::duration_cast<std::chrono::microseconds>(end - begin).count() <<std::endl;
            std::cout << "Time difference to serialize(ns) = " << std::chrono::duration_cast<std::chrono::nanoseconds> (end - begin).count() <<std::endl;

            begin = std::chrono::steady_clock::now();
            socket.send (request);
            end= std::chrono::steady_clock::now();

            std::cout << "send time(us) = " << std::chrono::duration_cast<std::chrono::microseconds>(end - begin).count() <<std::endl;
            std::cout << "send time(ns) = " << std::chrono::duration_cast<std::chrono::nanoseconds> (end - begin).count() <<std::endl;

            if (first_time == true) {
                dp.clear_channel_samples();
                first_time = false;
            }

        }
        sleep(1);

    }

}
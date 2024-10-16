/*
Copyright 2016 SuperDARN

See LICENSE for details.

  @file usrp.hpp
  This file contains class declarations for ease of use of USRP related
features.

*/
#ifndef SRC_USRP_DRIVERS_USRP_HPP_
#define SRC_USRP_DRIVERS_USRP_HPP_

#include <string>
#include <uhd/usrp/multi_usrp.hpp>
#include <uhd/usrp_clock/multi_usrp_clock.hpp>
#include <vector>

#include "utils/driveroptions.hpp"
#include "utils/shared_macros.hpp"

/**
 * @brief      Contains an abstract wrapper for the USRP object.
 */
class USRP {
 public:
  explicit USRP(const DriverOptions& driver_options, float tx_rate,
                float rx_rate);
  void set_usrp_clock_source(std::string source);
  void set_tx_subdev(std::string tx_subdev);
  double set_tx_rate(std::vector<size_t> chs);
  double get_tx_rate(uint32_t channel = 0);
  double set_tx_center_freq(double freq, std::vector<size_t> chs,
                            uhd::time_spec_t tune_delay);
  double get_tx_center_freq(uint32_t channel = 0);
  void set_main_rx_subdev(std::string main_subdev);
  void set_interferometer_rx_subdev(std::string interferometer_subdev,
                                    uint32_t interferometer_antenna_count);
  double set_rx_rate(std::vector<size_t> rx_chs);
  double get_rx_rate(uint32_t channel = 0);
  double set_rx_center_freq(double freq, std::vector<size_t> chs,
                            uhd::time_spec_t tune_delay);
  double get_rx_center_freq(uint32_t channel = 0);
  void set_time_source(std::string source, std::string clk_addr);
  void check_ref_locked();
  void create_usrp_rx_stream(std::string cpu_fmt, std::string otw_fmt,
                             std::vector<size_t> chs);
  void create_usrp_tx_stream(std::string cpu_fmt, std::string otw_fmt,
                             std::vector<size_t> chs);
  void set_command_time(uhd::time_spec_t cmd_time);
  void clear_command_time();
  std::vector<uint32_t> get_gpio_bank_high_state();
  std::vector<uint32_t> get_gpio_bank_low_state();
  uint32_t get_agc_status_bank_h();
  uint32_t get_lp_status_bank_h();
  uint32_t get_agc_status_bank_l();
  uint32_t get_lp_status_bank_l();
  uhd::time_spec_t get_current_usrp_time();
  uhd::rx_streamer::sptr get_usrp_rx_stream();
  uhd::tx_streamer::sptr get_usrp_tx_stream();
  uhd::usrp::multi_usrp::sptr get_usrp();
  std::string to_string(std::vector<size_t> tx_chs, std::vector<size_t> rx_chs);
  void invert_test_mode(uint32_t mboard = 0);
  void set_test_mode(uint32_t mboard = 0);
  void clear_test_mode(uint32_t mboard = 0);
  bool gps_locked(void);

 private:
  //! A shared pointer to a new multi-USRP device.
  uhd::usrp::multi_usrp::sptr usrp_;

  //! A shared pointer to a new multi-USRP-clock device.
  uhd::usrp_clock::multi_usrp_clock::sptr gps_clock_;

  //! A string representing what GPIO bank to use on the USRPs for active high
  //! sigs.
  std::string gpio_bank_high_;

  //! A string representing what GPIO bank to use on the USRPs for active low
  //! sigs.
  std::string gpio_bank_low_;

  //! The bitmask to use for the scope sync GPIO.
  uint32_t scope_sync_mask_;

  //! The bitmask to use for the attenuator GPIO.
  uint32_t atten_mask_;

  //! The bitmask to use for the TR GPIO.
  uint32_t tr_mask_;

  //! Bitmask used for full duplex ATR.
  uint32_t atr_xx_;

  //! Bitmask used for rx only ATR.
  uint32_t atr_rx_;

  //! Bitmask used for tx only ATR.
  uint32_t atr_tx_;

  //! Bitmask used for idle ATR.
  uint32_t atr_0x_;

  //! Bitmask used for AGC signal
  uint32_t agc_st_;

  //! Bitmask used for lo pwr signal
  uint32_t lo_pwr_;

  //! Bitmask used for test mode signal
  uint32_t test_mode_;

  //! The tx rate in Hz.
  float tx_rate_;

  //! The rx rate in Hz.
  float rx_rate_;

  uhd::tx_streamer::sptr tx_stream_;

  uhd::rx_streamer::sptr rx_stream_;

  void set_atr_gpios();

  void set_output_gpios();

  void set_input_gpios();
};

/**
 * @brief      Wrapper for the USRP TX metadata object.
 *
 * Used to hold and initialize a new tx_metadata_t object. Creates getters and
 * setters to access properties.
 */
class TXMetadata {
 public:
  TXMetadata();
  uhd::tx_metadata_t get_md();
  void set_start_of_burst(bool start_of_burst);
  void set_end_of_burst(bool end_of_burst);
  void set_has_time_spec(bool has_time_spec);
  void set_time_spec(uhd::time_spec_t time_spec);

 private:
  //! A raw USRP TX metadata object.
  uhd::tx_metadata_t md_;
};

/**
 * @brief      Wrapper for the USRP RX metadata object.
 *
 * Used to hold and initialize a new tx_metadata_t object. Creates getters and
 * setters to access properties.
 */
class RXMetadata {
 public:
  RXMetadata() = default;  // Blank ctor generated by compiler
  uhd::rx_metadata_t& get_md();
  bool get_end_of_burst();
  uhd::rx_metadata_t::error_code_t get_error_code();
  size_t get_fragment_offset();
  bool get_has_time_spec();
  bool get_out_of_sequence();
  bool get_start_of_burst();
  uhd::time_spec_t
  get_time_spec();  // REVIEW #6 TODO: add getter for more_fragments boolean
                    // REPLY can discuss.
 private:
  //! A raw USRP RX metadata object.
  uhd::rx_metadata_t md_;
};

#endif  // SRC_USRP_DRIVERS_USRP_HPP_

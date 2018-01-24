/*Copyright 2017 SuperDARN*/
#ifndef SHARED_MACROS_H
#define SHARED_MACROS_H

#include <zmq.hpp>
#include <iostream>
#include <chrono>

#define COLOR_BLACK(x)   "\033[30m"<< x << "\033[0m"       
#define COLOR_RED(x)     "\033[31m"<< x << "\033[0m"         
#define COLOR_GREEN(x)   "\033[32m"<< x << "\033[0m"        
#define COLOR_YELLOW(x)  "\033[33m"<< x << "\033[0m"         
#define COLOR_BLUE(x)    "\033[34m"<< x << "\033[0m"         
#define COLOR_MAGENTA(x) "\033[35m"<< x << "\033[0m"       
#define COLOR_CYAN(x)    "\033[36m"<< x << "\033[0m"         
#define COLOR_WHITE(x)   "\033[37m"<< x << "\033[0m"

#ifdef DEBUG
#define DEBUG_MSG(x) do {std::cerr << x << std::endl;} while (0)

#define TIMEIT_IF_DEBUG(msg,x) do { auto time_start = std::chrono::steady_clock::now();            \
                                    x;                                                             \
                                    auto time_end = std::chrono::steady_clock::now();              \
                                    auto time_diff = std::chrono::duration_cast                    \
                                                                        <std::chrono::microseconds>\
                                                    (time_end - time_start).count();               \
                                    DEBUG_MSG(msg << COLOR_MAGENTA(time_diff) << "us"); } while (0)
#else
#define DEBUG_MSG(x)
#define TIMEIT_IF_DEBUG(msg,x) do {x;} while(0)
#endif                                    

#define RUNTIME_MSG(x) do {std::cout << x << std::endl;} while (0)
#define ERR_CHK_ZMQ(x) try {x;} catch (zmq::error_t& e) {} //TODO(keith): handle error

#endif
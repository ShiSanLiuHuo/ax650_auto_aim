//
// MindVision MVSDK camera wrapper.
// Alternative camera backend to HikCamWrapper (Hikvision MVS), selected by
// CMake option USE_MINDVISION. The MVSDK runtime is installed on the AX650
// board by the EnvCfg one-click script.
//

#ifndef MINDVISION_WRAPPER_H
#define MINDVISION_WRAPPER_H

#include <opencv2/opencv.hpp>

#include "CameraApi.h"

#include "../cam_wrapper.hpp"

class MindVisionWrapper : public WrapperHead
{
public:
    MindVisionWrapper(int dev_num = 0, double exposure_ms = 3.0, double gamma = 1.0);
    ~MindVisionWrapper() override;

    bool init(bool debug = false) override;

    bool read(cv::Mat &src, bool debug = false) override;

    bool setBrightness(int brightness) override;

    int getFps() override;

    cv::Size getSize() override;

    bool close(bool debug = false) override;

private:
    CameraHandle handle_;
    int dev_num_;
    double exposure_ms_;
    double gamma_;
    int width_;
    int height_;
    unsigned int fail_cnt_;

    static constexpr unsigned int kGrabTimeoutMs = 1000;
    static constexpr unsigned int kFailLimit = 10;
};

#endif // MINDVISION_WRAPPER_H

#include "mindvision_wrapper.hpp"

#include <iostream>

namespace
{
constexpr int kMaxDevices = 16;
constexpr int kWarmupFrames = 5;
constexpr int kWarmupTimeoutMs = 100;
constexpr int kTriggerContinuous = 0; // 连续采集
constexpr int kFrameSpeedLow = 2;     // 低帧率模式

const char *StatusName(CameraSdkStatus status)
{
    const char *name = CameraGetErrorString(status);
    return name == nullptr ? "unknown" : name;
}
} // namespace

MindVisionWrapper::MindVisionWrapper(int dev_num, double exposure_ms, double gamma)
    : handle_(-1),
      dev_num_(dev_num),
      exposure_ms_(exposure_ms),
      gamma_(gamma),
      width_(0),
      height_(0),
      fail_cnt_(0)
{
}

MindVisionWrapper::~MindVisionWrapper()
{
    close();
}

bool MindVisionWrapper::init(bool debug)
{
    bool ok = false;

    do
    {
        if (CameraSdkInit(1) != CAMERA_STATUS_SUCCESS)
        {
            if (debug)
                std::cout << "CameraSdkInit fail!" << std::endl;
            break;
        }

        int camera_num = kMaxDevices;
        tSdkCameraDevInfo camera_list[kMaxDevices];
        const auto enum_ret = CameraEnumerateDevice(camera_list, &camera_num);
        if (enum_ret != CAMERA_STATUS_SUCCESS)
        {
            if (debug)
                std::cout << "CameraEnumerateDevice fail: " << StatusName(enum_ret) << std::endl;
            break;
        }
        if (camera_num <= 0)
        {
            if (debug)
                std::cout << "Find No Devices!" << std::endl;
            break;
        }
        if (dev_num_ < 0 || dev_num_ >= camera_num)
        {
            if (debug)
                std::cout << "Out Of Device Index (" << dev_num_ << " of " << camera_num << ")" << std::endl;
            break;
        }

        if (debug)
            std::cout << "Camera index: " << dev_num_ << std::endl;

        const auto init_ret = CameraInit(&camera_list[dev_num_], -1, -1, &handle_);
        if (init_ret != CAMERA_STATUS_SUCCESS)
        {
            handle_ = -1;
            if (debug)
                std::cout << "CameraInit fail: " << StatusName(init_ret) << std::endl;
            break;
        }

        tSdkCameraCapbility capability;
        const auto cap_ret = CameraGetCapability(handle_, &capability);
        if (cap_ret != CAMERA_STATUS_SUCCESS)
        {
            if (debug)
                std::cout << "CameraGetCapability fail: " << StatusName(cap_ret) << std::endl;
            break;
        }
        width_ = capability.sResolutionRange.iWidthMax;
        height_ = capability.sResolutionRange.iHeightMax;

        // 关闭自动曝光并使用固定曝光/伽马，输出 BGR8，连续采集。
        // 这些设置对部分机型可能不支持，失败时只记录，不影响取流。
        const auto ae_ret = CameraSetAeState(handle_, FALSE);
        if (ae_ret != CAMERA_STATUS_SUCCESS && debug)
            std::cout << "CameraSetAeState fail: " << StatusName(ae_ret) << std::endl;

        const auto exposure_ret = CameraSetExposureTime(handle_, exposure_ms_ * 1e3);
        if (exposure_ret != CAMERA_STATUS_SUCCESS && debug)
            std::cout << "CameraSetExposureTime fail: " << StatusName(exposure_ret) << std::endl;

        const auto gamma_ret = CameraSetGamma(handle_, static_cast<int>(gamma_ * 1e2));
        if (gamma_ret != CAMERA_STATUS_SUCCESS && debug)
            std::cout << "CameraSetGamma fail: " << StatusName(gamma_ret) << std::endl;

        const auto format_ret = CameraSetIspOutFormat(handle_, CAMERA_MEDIA_TYPE_BGR8);
        if (format_ret != CAMERA_STATUS_SUCCESS)
        {
            if (debug)
                std::cout << "CameraSetIspOutFormat fail: " << StatusName(format_ret) << std::endl;
            break;
        }

        const auto trigger_ret = CameraSetTriggerMode(handle_, kTriggerContinuous);
        if (trigger_ret != CAMERA_STATUS_SUCCESS)
        {
            if (debug)
                std::cout << "CameraSetTriggerMode fail: " << StatusName(trigger_ret) << std::endl;
            break;
        }

        const auto speed_ret = CameraSetFrameSpeed(handle_, kFrameSpeedLow);
        if (speed_ret != CAMERA_STATUS_SUCCESS && debug)
            std::cout << "CameraSetFrameSpeed fail: " << StatusName(speed_ret) << std::endl;

        const auto play_ret = CameraPlay(handle_);
        if (play_ret != CAMERA_STATUS_SUCCESS)
        {
            if (debug)
                std::cout << "CameraPlay fail: " << StatusName(play_ret) << std::endl;
            break;
        }

        // 丢弃启动过程中的前几帧，避免读到旧数据
        for (int i = 0; i < kWarmupFrames; ++i)
        {
            tSdkFrameHead head;
            BYTE *raw = nullptr;
            if (CameraGetImageBuffer(handle_, &head, &raw, kWarmupTimeoutMs) == CAMERA_STATUS_SUCCESS)
                CameraReleaseImageBuffer(handle_, raw);
        }

        ok = true;
    } while (0);

    if (!ok)
    {
        close(debug);
        return false;
    }

    fail_cnt_ = 0;
    return true;
}

bool MindVisionWrapper::close(bool debug)
{
    if (debug)
        std::cout << "closing MindVision camera..." << std::endl;

    if (handle_ < 0)
    {
        if (debug)
            std::cout << "MindVision handle is invalid, skip SDK close calls" << std::endl;
        return true;
    }

    CameraPause(handle_);
    const auto uninit_ret = CameraUnInit(handle_);
    handle_ = -1;
    width_ = 0;
    height_ = 0;

    if (uninit_ret != CAMERA_STATUS_SUCCESS)
    {
        if (debug)
            std::cout << "CameraUnInit fail: " << StatusName(uninit_ret) << std::endl;
        return false;
    }

    if (debug)
        std::cout << "MindVision camera closed" << std::endl;
    return true;
}

bool MindVisionWrapper::read(cv::Mat &src, bool debug)
{
    if (handle_ < 0)
    {
        if (!init(debug))
            return false;
    }

    if (fail_cnt_ > kFailLimit)
    {
        close(debug);
        fail_cnt_ = 0;
        if (!init(debug))
            return false;
    }

    tSdkFrameHead head;
    BYTE *raw = nullptr;
    const auto grab_ret = CameraGetImageBuffer(handle_, &head, &raw, kGrabTimeoutMs);
    if (grab_ret != CAMERA_STATUS_SUCCESS)
    {
        ++fail_cnt_;
        if (debug)
            std::cout << "CameraGetImageBuffer fail: " << StatusName(grab_ret) << std::endl;
        return false;
    }

    if (head.iWidth <= 0 || head.iHeight <= 0)
    {
        CameraReleaseImageBuffer(handle_, raw);
        ++fail_cnt_;
        if (debug)
            std::cout << "CameraGetImageBuffer returned empty frame" << std::endl;
        return false;
    }

    // 按当前帧尺寸分配目标缓冲，避免机型分辨率与能力上限不一致时越界。
    src.create(head.iHeight, head.iWidth, CV_8UC3);

    const auto process_ret = CameraImageProcess(handle_, raw, src.data, &head);
    CameraReleaseImageBuffer(handle_, raw);

    if (process_ret != CAMERA_STATUS_SUCCESS)
    {
        ++fail_cnt_;
        if (debug)
            std::cout << "CameraImageProcess fail: " << StatusName(process_ret) << std::endl;
        return false;
    }

    fail_cnt_ = 0;
    return true;
}

bool MindVisionWrapper::setBrightness(int brightness)
{
    if (handle_ < 0)
    {
        std::cerr << "[MindVisionWrapper] setBrightness called with invalid camera handle" << std::endl;
        return false;
    }

    return CameraSetAnalogGain(handle_, brightness) == CAMERA_STATUS_SUCCESS;
}

int MindVisionWrapper::getFps()
{
    if (handle_ < 0)
    {
        std::cerr << "[MindVisionWrapper] getFps called with invalid camera handle" << std::endl;
        return 0;
    }

    int rate = 0;
    if (CameraGetFrameRate(handle_, &rate) != CAMERA_STATUS_SUCCESS)
        return 0;
    return rate;
}

cv::Size MindVisionWrapper::getSize()
{
    if (handle_ < 0)
    {
        std::cerr << "[MindVisionWrapper] getSize called with invalid camera handle" << std::endl;
        return cv::Size(0, 0);
    }

    return cv::Size(width_, height_);
}

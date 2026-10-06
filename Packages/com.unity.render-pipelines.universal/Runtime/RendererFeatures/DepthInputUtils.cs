using UnityEngine;
using UnityEngine.Rendering;
using UnityEngine.Rendering.Universal;

public class DepthInputUtils
{
    public const string DEPTH_INPUT_ATTACHMENT = "_DEPTH_INPUT_ATTACHMENT";

    public static bool IsSupported()
    {
        bool supportAPI = SystemInfo.graphicsDeviceType == GraphicsDeviceType.Vulkan || SystemInfo.graphicsDeviceType == GraphicsDeviceType.Direct3D12;
        return supportAPI && !UniversalRenderPipeline.asset.supportsCameraDepthTexture;
    }
}

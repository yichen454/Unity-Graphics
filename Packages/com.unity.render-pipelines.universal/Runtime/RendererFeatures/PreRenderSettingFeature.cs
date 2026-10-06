using System;
using UnityEngine;
using UnityEngine.Rendering;
using UnityEngine.Rendering.Universal;
using UnityEngine.Rendering.RenderGraphModule;

public class PreRenderSettingFeature : ScriptableRendererFeature
{
    PreRenderSettingFeaturePass m_ScriptablePass;
    [SerializeField] PreRenderSettingFeatureSettings settings = new PreRenderSettingFeatureSettings();

    /// <inheritdoc/>
    public override void Create()
    {
        m_ScriptablePass = new PreRenderSettingFeaturePass(settings)
        {
            // Configures where the render pass should be injected.
            renderPassEvent = settings.renderPassEvent
        };

        // You can request URP color texture and depth buffer as inputs by uncommenting the line below,
        // URP will ensure copies of these resources are available for sampling before executing the render pass.
        // Only uncomment it if necessary, it will have a performance impact, especially on mobiles and other TBDR GPUs where it will break render passes.
        //m_ScriptablePass.ConfigureInput(ScriptableRenderPassInput.Color | ScriptableRenderPassInput.Depth);

        // You can request URP to render to an intermediate texture by uncommenting the line below.
        // Use this option for passes that do not support rendering directly to the backbuffer.
        // Only uncomment it if necessary, it will have a performance impact, especially on mobiles and other TBDR GPUs where it will break render passes.
        //m_ScriptablePass.requiresIntermediateTexture = true;
    }

    // Here you can inject one or multiple render passes in the renderer.
    // This method is called when setting up the renderer once per-camera.
    public override void AddRenderPasses(ScriptableRenderer renderer, ref RenderingData renderingData)
    {
        renderer.EnqueuePass(m_ScriptablePass);
    }

    // Use this class to pass around settings from the feature to the pass
    [Serializable]
    public class PreRenderSettingFeatureSettings
    {
        public RenderPassEvent renderPassEvent = RenderPassEvent.BeforeRendering;
        public bool enableDepthInputAttachment = true;
    }

    class PreRenderSettingFeaturePass : ScriptableRenderPass
    {
        readonly PreRenderSettingFeatureSettings settings;

        private static GlobalKeyword m_depthInputKeyword;

        public PreRenderSettingFeaturePass(PreRenderSettingFeatureSettings settings)
        {
            this.settings = settings;
            m_depthInputKeyword = GlobalKeyword.Create(DepthInputUtils.DEPTH_INPUT_ATTACHMENT);
        }

        // This class stores the data needed by the RenderGraph pass.
        // It is passed as a parameter to the delegate function that executes the RenderGraph pass.
        private class PassData
        {

        }

        // This static method is passed as the RenderFunc delegate to the RenderGraph render pass.
        // It is used to execute draw commands.
        void ExecutePass(PassData data, RasterGraphContext context)
        {
            bool isOpen = settings.enableDepthInputAttachment && DepthInputUtils.IsSupported();
            context.cmd.SetKeyword(m_depthInputKeyword, isOpen);
        }

        // RecordRenderGraph is where the RenderGraph handle can be accessed, through which render passes can be added to the graph.
        // FrameData is a context container through which URP resources can be accessed and managed.
        public override void RecordRenderGraph(RenderGraph renderGraph, ContextContainer frameData)
        {
            const string passName = "PreRenderSettingFeaturePass";

            // This adds a raster render pass to the graph, specifying the name and the data type that will be passed to the ExecutePass function.
            using (var builder = renderGraph.AddRasterRenderPass<PassData>(passName, out var passData))
            {
                // Use this scope to set the required inputs and outputs of the pass and to
                // setup the passData with the required properties needed at pass execution time.

                // Make use of frameData to access resources and camera data through the dedicated containers.
                // Eg:
                // UniversalCameraData cameraData = frameData.Get<UniversalCameraData>();
                UniversalResourceData resourceData = frameData.Get<UniversalResourceData>();


                builder.AllowPassCulling(false);

                // This sets the render target of the pass to the active color texture. Change it to your own render target as needed.
                // builder.SetRenderAttachment(resourceData.activeColorTexture, 0);

                builder.AllowGlobalStateModification(true);
                // Assigns the ExecutePass function to the render pass delegate. This will be called by the render graph when executing the pass.
                builder.SetRenderFunc((PassData data, RasterGraphContext context) => ExecutePass(data, context));
            }
        }
    }
}

#if canImport(UIKit)

import UIKit

public protocol RenderViewDelegate: class {
    func willDisplayFramebuffer(renderView: RenderView, framebuffer: Framebuffer)
    func didDisplayFramebuffer(renderView: RenderView, framebuffer: Framebuffer)
    // Only use this if you need to do layout in willDisplayFramebuffer before the framebuffer actually gets displayed
    // Typically should only be used for one frame otherwise will cause serious playback issues
    // When true the above delegate methods will be called from the main thread instead of the sharedImageProcessing que
    // Default is false
    func shouldDisplayNextFramebufferAfterMainThreadLoop() -> Bool
}

public class RenderView:UIView, ImageConsumer {
    public weak var delegate:RenderViewDelegate?
    
    public var backgroundRenderColor = Color.black
    public var fillMode = FillMode.preserveAspectRatio
    public var orientation:ImageOrientation = .portrait
    public var sizeInPixels:Size { get { return Size(width:Float(frame.size.width * contentScaleFactor), height:Float(frame.size.height * contentScaleFactor))}}
    
    public let sources = SourceContainer()
    public let maximumInputs:UInt = 1
    var displayFramebuffer:GLuint?
    var displayRenderbuffer:GLuint?
    var backingSize = GLSize(width:0, height:0)
    
    private lazy var displayShader:ShaderProgram = {
        return sharedImageProcessingContext.passthroughShader
    }()

    private var internalLayer: CAEAGLLayer!
    
    required public init?(coder:NSCoder) {
        super.init(coder:coder)
        self.commonInit()
    }

    public override init(frame:CGRect) {
        super.init(frame:frame)
        self.commonInit()
    }

    override public class var layerClass:Swift.AnyClass {
        get {
            return CAEAGLLayer.self
        }
    }
    
    override public var bounds: CGRect {
        didSet {
            // Check if the size changed
            if(oldValue.size != self.bounds.size) {
                // Destroy the displayFramebuffer so we render at the correct size for the next frame
                sharedImageProcessingContext.runOperationAsynchronously{ [unowned self] in
                    self.destroyDisplayFramebuffer()
                }
            }
        }
    }
    
    func commonInit() {
        self.contentScaleFactor = UIScreen.main.scale
        
        let eaglLayer = self.layer as! CAEAGLLayer
        eaglLayer.isOpaque = true
        eaglLayer.drawableProperties = [kEAGLDrawablePropertyRetainedBacking: false, kEAGLDrawablePropertyColorFormat: kEAGLColorFormatRGBA8]
        eaglLayer.contentsGravity = kCAGravityResizeAspectFill // Just for safety to prevent distortion
        
        internalLayer = eaglLayer
    }
    
    deinit {
        sharedImageProcessingContext.runOperationSynchronously{
            destroyDisplayFramebuffer()
        }
    }
    
    func createDisplayFramebuffer() -> Bool {
        var newDisplayFramebuffer:GLuint = 0
        glGenFramebuffers(1, &newDisplayFramebuffer)
        displayFramebuffer = newDisplayFramebuffer
        glBindFramebuffer(GLenum(GL_FRAMEBUFFER), displayFramebuffer!)

        var newDisplayRenderbuffer:GLuint = 0
        glGenRenderbuffers(1, &newDisplayRenderbuffer)
        displayRenderbuffer = newDisplayRenderbuffer
        glBindRenderbuffer(GLenum(GL_RENDERBUFFER), displayRenderbuffer!)
        
        // Without the flush you will occasionally get a warning from UIKit and when that happens the RenderView just stays black.
        
        // "CoreAnimation: [EAGLContext renderbufferStorage:fromDrawable:] was called from a non-main thread in an implicit transaction!
        // Note that this may be unsafe without an explicit CATransaction or a call to [CATransaction flush]."
        // I tried a transaction and that doesn't work and this is probably why --> http://danielkbx.com/post/108060601989/catransaction-flush
        // Using flush is important because it guarantees the view is layed out at the correct size before it is drawn to since this is being done on a background thread.
        // Its possible the size of the view was changed right before we got here and would result in us drawing to the view at the old size
        // and then the view size would change to the new size at the next layout pass and distort our already drawn image.
        // Since we do not call this function often we do not need to worry about the performance impact of calling flush.
        CATransaction.flush()
        sharedImageProcessingContext.context.renderbufferStorage(Int(GL_RENDERBUFFER), from:self.internalLayer)
        
        var backingWidth:GLint = 0
        var backingHeight:GLint = 0
        glGetRenderbufferParameteriv(GLenum(GL_RENDERBUFFER), GLenum(GL_RENDERBUFFER_WIDTH), &backingWidth)
        glGetRenderbufferParameteriv(GLenum(GL_RENDERBUFFER), GLenum(GL_RENDERBUFFER_HEIGHT), &backingHeight)
        backingSize = GLSize(width:backingWidth, height:backingHeight)
        
        guard (backingWidth > 0 && backingHeight > 0) else {
            print("WARNING: View had a zero size")
            
            if(self.internalLayer.bounds.width > 0 && self.internalLayer.bounds.height > 0) {
                print("WARNING: View size \(self.internalLayer.bounds) may be too large ")
            }
            return false
        }
        
        glFramebufferRenderbuffer(GLenum(GL_FRAMEBUFFER), GLenum(GL_COLOR_ATTACHMENT0), GLenum(GL_RENDERBUFFER), displayRenderbuffer!)
        
        let status = glCheckFramebufferStatus(GLenum(GL_FRAMEBUFFER))
        if (status != GLenum(GL_FRAMEBUFFER_COMPLETE)) {
            print("Display framebuffer creation failed with error: \(FramebufferCreationError(errorCode:status))")
            return false
        }
        
        return true
    }
    
    func destroyDisplayFramebuffer() {
        if let displayFramebuffer = self.displayFramebuffer {
            var temporaryFramebuffer = displayFramebuffer
            glDeleteFramebuffers(1, &temporaryFramebuffer)
            self.displayFramebuffer = nil
        }
        
        if let displayRenderbuffer = self.displayRenderbuffer {
            var temporaryRenderbuffer = displayRenderbuffer
            glDeleteRenderbuffers(1, &temporaryRenderbuffer)
            self.displayRenderbuffer = nil
        }
    }
    
    func activateDisplayFramebuffer() {
        glBindFramebuffer(GLenum(GL_FRAMEBUFFER), displayFramebuffer!)
        glViewport(0, 0, backingSize.width, backingSize.height)
    }
    
    public func newFramebufferAvailable(_ framebuffer:Framebuffer, fromSourceIndex:UInt) {
        let cleanup: () -> Void = {
            if(self.delegate?.shouldDisplayNextFramebufferAfterMainThreadLoop() ?? false) {
                DispatchQueue.main.async {
                    self.delegate?.didDisplayFramebuffer(renderView: self, framebuffer: framebuffer)
                    framebuffer.unlock()
                }
            }
            else {
                self.delegate?.didDisplayFramebuffer(renderView: self, framebuffer: framebuffer)
                framebuffer.unlock()
            }
        }
        
        let work: () -> Void = {
            if (self.displayFramebuffer == nil && !self.createDisplayFramebuffer()) {
                cleanup()
                // Bail if we couldn't successfully create the displayFramebuffer
                return
            }
            self.activateDisplayFramebuffer()
            
            clearFramebufferWithColor(self.backgroundRenderColor)
            
            let scaledVertices = self.fillMode.transformVertices(verticallyInvertedImageVertices, fromInputSize:framebuffer.sizeForTargetOrientation(self.orientation), toFitSize:self.backingSize)
            renderQuadWithShader(self.displayShader, vertices:scaledVertices, inputTextures:[framebuffer.texturePropertiesForTargetOrientation(self.orientation)])
            
            glBindRenderbuffer(GLenum(GL_RENDERBUFFER), self.displayRenderbuffer!)
            
            sharedImageProcessingContext.presentBufferForDisplay()
            
            cleanup()
        }
        
        if(self.delegate?.shouldDisplayNextFramebufferAfterMainThreadLoop() ?? false) {
            // CAUTION: Never call sync from the sharedImageProcessingContext, it will cause cyclic thread deadlocks
            // If you are curious, change this to sync, then try trimming/scrubbing a video
            // Before that happens you will get a deadlock when someone calls runOperationSynchronously since the main thread is blocked
            // There is a way to get around this but then the first thing mentioned will happen
            DispatchQueue.main.async {
                self.delegate?.willDisplayFramebuffer(renderView: self, framebuffer: framebuffer)
                
                sharedImageProcessingContext.runOperationAsynchronously {
                    work()
                }
            }
        }
        else {
            self.delegate?.willDisplayFramebuffer(renderView: self, framebuffer: framebuffer)
            
            work()
        }
    }
}
#endif

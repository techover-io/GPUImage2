import AVFoundation

public protocol MovieInputDelegate: class {
    func didFinishMovie()
}

public class MovieInput: ImageSource {
    public let targets = TargetContainer()
    public var runBenchmark = false
    
    public weak var delegate: MovieInputDelegate?
    
    public weak var audioEncodingTarget:AudioEncodingTarget? {
        didSet {
            guard let audioEncodingTarget = audioEncodingTarget else {
                return
            }
            audioEncodingTarget.activateAudioTrack()
            
            // Call enableSynchronizedEncoding() again if they didn't set the audioEncodingTarget before setting synchronizedMovieOutput.
            if(synchronizedMovieOutput != nil) {
                enableSynchronizedEncoding()
            }
        }
    }
    
    let yuvConversionShader:ShaderProgram
    let asset:AVAsset
    let videoComposition:AVVideoComposition?
    var playAtActualSpeed:Bool
    
    // Time in the video where it should start.
    var requestedStartTime:CMTime?
    // Time in the video where it started.
    var startTime:CMTime?
    // Time according to device clock when the video started.
    var actualStartTime:DispatchTime?
    // Last sample time that played.
    private(set) public var currentTime:CMTime?
    
    public var loop:Bool
    
    // Called after the video finishes. Not called when cancel() or pause() is called.
    public var completion: (() -> Void)?
    // Progress block of the video with a paramater value of 0-1.
    // Can be used to check video encoding progress. Not called from main thread.
    public var progress: ((Double) -> Void)?
    
    public weak var synchronizedMovieOutput: MovieOutput? {
        didSet {
            enableSynchronizedEncoding()
        }
    }
    public var synchronizedEncodingDebug = false {
        didSet {
            synchronizedMovieOutput?.synchronizedEncodingDebug = synchronizedEncodingDebug
        }
    }
    let conditionLock = NSCondition()
    var readingShouldWait = false
    var videoInputStatusObserver:NSKeyValueObservation?
    var audioInputStatusObserver:NSKeyValueObservation?
    
    public var useRealtimeThreads = false
    var timebaseInfo = mach_timebase_info_data_t()
    var currentThread:Thread?
    
    var totalFramesSent = 0
    var totalFrameTimeDuringCapture:Double = 0.0
    
    var audioSettings:[String:Any]?
    
    var movieFramebuffer:Framebuffer?
    public var framebufferUserInfo:[AnyHashable:Any]?
    
    // TODO: Someone will have to add back in the AVPlayerItem logic, because I don't know how that works
    public init(asset:AVAsset, videoComposition: AVVideoComposition?, playAtActualSpeed:Bool = false, loop:Bool = false, audioSettings:[String:Any]? = nil) throws {
        self.asset = asset
        self.videoComposition = videoComposition
        self.playAtActualSpeed = playAtActualSpeed
        self.loop = loop
        self.yuvConversionShader = crashOnShaderCompileFailure("MovieInput"){try sharedImageProcessingContext.programForVertexShader(defaultVertexShaderForInputs(2), fragmentShader:YUVConversionFullRangeFragmentShader)}
        self.audioSettings = audioSettings
    }
    
    public convenience init(url:URL, playAtActualSpeed:Bool = false, loop:Bool = false, audioSettings:[String:Any]? = nil) throws {
        let inputOptions = [AVURLAssetPreferPreciseDurationAndTimingKey:NSNumber(value:true)]
        let inputAsset = AVURLAsset(url:url, options:inputOptions)
        try self.init(asset:inputAsset, videoComposition: nil, playAtActualSpeed:playAtActualSpeed, loop:loop, audioSettings:audioSettings)
    }
    
    deinit {
        movieFramebuffer?.unlock()
        cancel()
        
        videoInputStatusObserver?.invalidate()
        audioInputStatusObserver?.invalidate()
    }
    
    // MARK: -
    // MARK: Playback control
    
    public func start(atTime: CMTime) {
        requestedStartTime = atTime
        start()
    }
    
    @objc public func start() {
        if let currentThread = currentThread,
            currentThread.isExecuting,
            !currentThread.isCancelled {
            // If the current thread is running and has not been cancelled, bail.
            return
        }
        // Cancel the thread just to be safe in the event we somehow get here with the thread still running.
        currentThread?.cancel()
        
        currentThread = Thread(target: self, selector: #selector(beginReading), object: nil)
        currentThread?.start()
    }
    
    public func cancel() {
        currentThread?.cancel()
        currentThread = nil
    }
    
    public func pause() {
        cancel()
        requestedStartTime = currentTime
    }
    
    // MARK: -
    // MARK: Internal processing functions
    
    func createReader() -> AVAssetReader?
    {
        do {
            let outputSettings:[String:AnyObject] =
                [(kCVPixelBufferPixelFormatTypeKey as String):NSNumber(value:Int32(kCVPixelFormatType_420YpCbCr8BiPlanarFullRange))]
            
            let assetReader = try AVAssetReader.init(asset: asset)
            
            if(videoComposition == nil) {
                let readerVideoTrackOutput = AVAssetReaderTrackOutput(track: asset.tracks(withMediaType: .video).first!, outputSettings:outputSettings)
                readerVideoTrackOutput.alwaysCopiesSampleData = false
                assetReader.add(readerVideoTrackOutput)
            }
            else {
                let readerVideoTrackOutput = AVAssetReaderVideoCompositionOutput(videoTracks: asset.tracks(withMediaType: .video), videoSettings: outputSettings)
                readerVideoTrackOutput.videoComposition = videoComposition
                readerVideoTrackOutput.alwaysCopiesSampleData = false
                assetReader.add(readerVideoTrackOutput)
            }
            
            if let audioTrack = asset.tracks(withMediaType: .audio).first,
                let _ = audioEncodingTarget {
                let readerAudioTrackOutput = AVAssetReaderTrackOutput(track: audioTrack, outputSettings: audioSettings)
                readerAudioTrackOutput.alwaysCopiesSampleData = false
                assetReader.add(readerAudioTrackOutput)
            }
            
            startTime = requestedStartTime
            if let requestedStartTime = requestedStartTime {
                assetReader.timeRange = CMTimeRange(start: requestedStartTime, duration: kCMTimePositiveInfinity)
            }
            requestedStartTime = nil
            currentTime = nil
            actualStartTime = nil
            
            return assetReader
        } catch {
            print("ERROR: Unable to create asset reader: \(error)")
        }
        return nil
    }
    
    @objc func beginReading() {
        let thread = Thread.current
        
        mach_timebase_info(&timebaseInfo)
        
        if(useRealtimeThreads) {
            configureThread()
        }
        else if(playAtActualSpeed) {
            thread.qualityOfService = .userInitiated
        }
        else {
            // This includes synchronized encoding since the above vars will be disabled for it.
            thread.qualityOfService = .default
        }
        
        guard let assetReader = createReader() else {
            return // A return statement in this frame will end thread execution.
        }
        
        do {
            try NSObject.catchException {
                guard assetReader.startReading() else {
                    print("ERROR: Unable to start reading: \(String(describing: assetReader.error))")
                    return
                }
            }
        }
        catch {
            print("ERROR: Unable to start reading: \(error)")
            return
        }
        
        var readerVideoTrackOutput:AVAssetReaderOutput? = nil
        var readerAudioTrackOutput:AVAssetReaderOutput? = nil
        
        for output in assetReader.outputs {
            if(output.mediaType == AVMediaType.video.rawValue) {
                readerVideoTrackOutput = output
            }
            if(output.mediaType == AVMediaType.audio.rawValue) {
                readerAudioTrackOutput = output
            }
        }
        
        while(assetReader.status == .reading) {
            if (thread.isCancelled) {
                break
            }
            
            if let movieOutput = synchronizedMovieOutput {
                conditionLock.lock()
                if(readingShouldWait) {
                    synchronizedEncodingDebugPrint("Disable reading")
                    conditionLock.wait()
                    synchronizedEncodingDebugPrint("Enable reading")
                }
                conditionLock.unlock()
                
                if(movieOutput.assetWriterVideoInput.isReadyForMoreMediaData) {
                    readNextVideoFrame(with: assetReader, from: readerVideoTrackOutput!)
                }
                if(movieOutput.assetWriterAudioInput?.isReadyForMoreMediaData ?? false) {
                    if let readerAudioTrackOutput = readerAudioTrackOutput {
                        readNextAudioSample(with: assetReader, from: readerAudioTrackOutput)
                    }
                }
            }
            else {
                readNextVideoFrame(with: assetReader, from: readerVideoTrackOutput!)
                if let readerAudioTrackOutput = readerAudioTrackOutput,
                    audioEncodingTarget?.readyForNextAudioBuffer() ?? true {
                    readNextAudioSample(with: assetReader, from: readerAudioTrackOutput)
                }
            }
        }
        
        assetReader.cancelReading()
        
        // Since only the main thread will cancel and create threads jump onto it to prevent
        // the current thread from being cancelled in between the below if statement and creating the new thread.
        DispatchQueue.main.async { [weak self] in
            guard let weakSelf = self else {
                print("Weak self - return")
                return
            }
            // Start the video over so long as it wasn't cancelled.
            if (weakSelf.loop && !thread.isCancelled) {
                weakSelf.currentThread = Thread(target: weakSelf, selector: #selector(weakSelf.beginReading), object: nil)
                weakSelf.currentThread?.start()
            }
            else {
                weakSelf.delegate?.didFinishMovie()
                weakSelf.completion?()
                
                weakSelf.synchronizedEncodingDebugPrint("MovieInput finished reading")
                weakSelf.synchronizedEncodingDebugPrint("MovieInput total frames sent: \(weakSelf.totalFramesSent)")
            }
        }
    }
    
    func readNextVideoFrame(with assetReader: AVAssetReader, from videoTrackOutput:AVAssetReaderOutput) {
        guard let sampleBuffer = videoTrackOutput.copyNextSampleBuffer() else {
            if let movieOutput = self.synchronizedMovieOutput {
                movieOutput.movieProcessingContext.runOperationAsynchronously {
                    // Documentation: "Clients that are monitoring each input's readyForMoreMediaData value must call markAsFinished on an input when they are done
                    // appending buffers to it. This is necessary to prevent other inputs from stalling, as they may otherwise wait forever
                    // for that input's media data, attempting to complete the ideal interleaving pattern."
                    movieOutput.videoEncodingIsFinished = true
                    movieOutput.assetWriterVideoInput.markAsFinished()
                }
            }
            return
        }
        
        
        synchronizedEncodingDebugPrint("Process frame input")
        
        var currentSampleTime = CMSampleBufferGetOutputPresentationTimeStamp(sampleBuffer)
        var duration = asset.duration // Only used for the progress block so its acuracy is not critical
        
        currentTime = currentSampleTime
        
        if let startTime = self.startTime {
            // Make sure our samples start at kCMTimeZero if the video was started midway.
            currentSampleTime = CMTimeSubtract(currentSampleTime, startTime)
            duration = CMTimeSubtract(duration, startTime)
        }
        
        if (playAtActualSpeed) {
            let currentSampleTimeNanoseconds = Int64(currentSampleTime.seconds * 1_000_000_000)
            let currentActualTime = DispatchTime.now()
            
            if(self.actualStartTime == nil) { self.actualStartTime = currentActualTime }
            
            // Determine how much time we need to wait in order to display the frame at the right currentActualTime such that it will match the currentSampleTime.
            // The reason we subtract the actualStartTime from the currentActualTime is so the actual time starts at zero relative to the video start.
            let delay = currentSampleTimeNanoseconds - Int64(currentActualTime.uptimeNanoseconds-self.actualStartTime!.uptimeNanoseconds)
            
            //print("currentSampleTime: \(currentSampleTimeNanoseconds) currentTime: \((currentActualTime.uptimeNanoseconds-self.actualStartTime!.uptimeNanoseconds)) delay: \(delay)")
            
            if(delay > 0) {
                mach_wait_until(mach_absolute_time() + self.nanosToAbs(UInt64(delay)))
            }
            else {
                // This only happens if we aren't given enough processing time for playback
                // but is necessary otherwise the playback will never catch up to its timeline.
                // If we weren't adhearing to the sample timline and used the old timing method
                // the video would still lag during an event like this.
                //print("Dropping frame in order to catch up")
                return
            }
        }
        
        progress?(currentSampleTime.seconds/duration.seconds)
        
        sharedImageProcessingContext.runOperationSynchronously {
            process(movieFrame:sampleBuffer)
            CMSampleBufferInvalidate(sampleBuffer)
        }
    }
    
    func readNextAudioSample(with assetReader: AVAssetReader, from audioTrackOutput:AVAssetReaderOutput) {
        guard let sampleBuffer = audioTrackOutput.copyNextSampleBuffer() else {
            if let movieOutput = self.synchronizedMovieOutput {
                movieOutput.movieProcessingContext.runOperationAsynchronously {
                    movieOutput.audioEncodingIsFinished = true
                    movieOutput.assetWriterAudioInput?.markAsFinished()
                }
            }
            return
        }
        
        synchronizedEncodingDebugPrint("Process audio sample input")
        
        audioEncodingTarget?.processAudioBuffer(sampleBuffer, shouldInvalidateSampleWhenDone: true)
    }
    
    func process(movieFrame frame:CMSampleBuffer) {
        let currentSampleTime = CMSampleBufferGetOutputPresentationTimeStamp(frame)
        let movieFrame = CMSampleBufferGetImageBuffer(frame)!
        
        process(movieFrame:movieFrame, withSampleTime:currentSampleTime)
    }
    
    func process(movieFrame:CVPixelBuffer, withSampleTime:CMTime) {
        let bufferHeight = CVPixelBufferGetHeight(movieFrame)
        let bufferWidth = CVPixelBufferGetWidth(movieFrame)
        CVPixelBufferLockBaseAddress(movieFrame, CVPixelBufferLockFlags(rawValue:CVOptionFlags(0)))
        
        let conversionMatrix = colorConversionMatrix601FullRangeDefault
        // TODO: Get this color query working
        //        if let colorAttachments = CVBufferGetAttachment(movieFrame, kCVImageBufferYCbCrMatrixKey, nil) {
        //            if(CFStringCompare(colorAttachments, kCVImageBufferYCbCrMatrix_ITU_R_601_4, 0) == .EqualTo) {
        //                _preferredConversion = kColorConversion601FullRange
        //            } else {
        //                _preferredConversion = kColorConversion709
        //            }
        //        } else {
        //            _preferredConversion = kColorConversion601FullRange
        //        }
        
        let startTime = CFAbsoluteTimeGetCurrent()
        
        var luminanceGLTexture: CVOpenGLESTexture?
        
        glActiveTexture(GLenum(GL_TEXTURE0))
        
        let luminanceGLTextureResult = CVOpenGLESTextureCacheCreateTextureFromImage(kCFAllocatorDefault, sharedImageProcessingContext.coreVideoTextureCache, movieFrame, nil, GLenum(GL_TEXTURE_2D), GL_LUMINANCE, GLsizei(bufferWidth), GLsizei(bufferHeight), GLenum(GL_LUMINANCE), GLenum(GL_UNSIGNED_BYTE), 0, &luminanceGLTexture)
        
        if(luminanceGLTextureResult != kCVReturnSuccess || luminanceGLTexture == nil) {
            print("Could not create LuminanceGLTexture")
            return
        }
        
        let luminanceTexture = CVOpenGLESTextureGetName(luminanceGLTexture!)
        
        glBindTexture(GLenum(GL_TEXTURE_2D), luminanceTexture)
        glTexParameterf(GLenum(GL_TEXTURE_2D), GLenum(GL_TEXTURE_WRAP_S), GLfloat(GL_CLAMP_TO_EDGE));
        glTexParameterf(GLenum(GL_TEXTURE_2D), GLenum(GL_TEXTURE_WRAP_T), GLfloat(GL_CLAMP_TO_EDGE));
        
        let luminanceFramebuffer: Framebuffer
        do {
            luminanceFramebuffer = try Framebuffer(context: sharedImageProcessingContext, orientation: .portrait, size: GLSize(width:GLint(bufferWidth), height:GLint(bufferHeight)), textureOnly: true, overriddenTexture: luminanceTexture)
        } catch {
            print("Could not create a framebuffer of the size (\(bufferWidth), \(bufferHeight)), error: \(error)")
            return
        }
        
        var chrominanceGLTexture: CVOpenGLESTexture?
        
        glActiveTexture(GLenum(GL_TEXTURE1))
        
        let chrominanceGLTextureResult = CVOpenGLESTextureCacheCreateTextureFromImage(kCFAllocatorDefault, sharedImageProcessingContext.coreVideoTextureCache, movieFrame, nil, GLenum(GL_TEXTURE_2D), GL_LUMINANCE_ALPHA, GLsizei(bufferWidth / 2), GLsizei(bufferHeight / 2), GLenum(GL_LUMINANCE_ALPHA), GLenum(GL_UNSIGNED_BYTE), 1, &chrominanceGLTexture)
        
        if(chrominanceGLTextureResult != kCVReturnSuccess || chrominanceGLTexture == nil) {
            print("Could not create ChrominanceGLTexture")
            return
        }
        
        let chrominanceTexture = CVOpenGLESTextureGetName(chrominanceGLTexture!)
        
        glBindTexture(GLenum(GL_TEXTURE_2D), chrominanceTexture)
        glTexParameterf(GLenum(GL_TEXTURE_2D), GLenum(GL_TEXTURE_WRAP_S), GLfloat(GL_CLAMP_TO_EDGE));
        glTexParameterf(GLenum(GL_TEXTURE_2D), GLenum(GL_TEXTURE_WRAP_T), GLfloat(GL_CLAMP_TO_EDGE));
        
        let chrominanceFramebuffer: Framebuffer
        do {
            chrominanceFramebuffer = try Framebuffer(context: sharedImageProcessingContext, orientation: .portrait, size: GLSize(width:GLint(bufferWidth), height:GLint(bufferHeight)), textureOnly: true, overriddenTexture: chrominanceTexture)
        } catch {
            print("Could not create a framebuffer of the size (\(bufferWidth), \(bufferHeight)), error: \(error)")
            return
        }
        
        self.movieFramebuffer?.unlock()
        let movieFramebuffer = sharedImageProcessingContext.framebufferCache.requestFramebufferWithProperties(orientation:.portrait, size:GLSize(width:GLint(bufferWidth), height:GLint(bufferHeight)), textureOnly:false)
        movieFramebuffer.lock()
        
        convertYUVToRGB(shader:self.yuvConversionShader, luminanceFramebuffer:luminanceFramebuffer, chrominanceFramebuffer:chrominanceFramebuffer, resultFramebuffer:movieFramebuffer, colorConversionMatrix:conversionMatrix)
        CVPixelBufferUnlockBaseAddress(movieFrame, CVPixelBufferLockFlags(rawValue:CVOptionFlags(0)))
        
        movieFramebuffer.timingStyle = .videoFrame(timestamp:Timestamp(withSampleTime))
        movieFramebuffer.userInfo = self.framebufferUserInfo
        self.movieFramebuffer = movieFramebuffer
        
        updateTargetsWithFramebuffer(movieFramebuffer)
        
        if(runBenchmark || synchronizedEncodingDebug) {
            totalFramesSent += 1
        }
        
        if (runBenchmark) {
            let currentFrameTime = (CFAbsoluteTimeGetCurrent() - startTime)
            totalFrameTimeDuringCapture += currentFrameTime
            print("Average frame time : \(1000.0 * self.totalFrameTimeDuringCapture / Double(self.totalFramesSent)) ms")
            print("Current frame time : \(1000.0 * currentFrameTime) ms")
        }
    }
    
    public func transmitPreviousImage(to target:ImageConsumer, atIndex:UInt) {
        // Not needed for movie inputs
    }
    
    public func transmitPreviousFrame() {
        sharedImageProcessingContext.runOperationAsynchronously { [weak self] in
            if let movieFramebuffer = self?.movieFramebuffer {
                self?.updateTargetsWithFramebuffer(movieFramebuffer)
            }
        }
    }
    
    // MARK: -
    // MARK: Synchronized encoding
    
    func enableSynchronizedEncoding() {
        synchronizedMovieOutput?.encodingLiveVideo = false
        synchronizedMovieOutput?.synchronizedEncodingDebug = synchronizedEncodingDebug
        playAtActualSpeed = false
        loop = false
        
        // Subscribe to isReadyForMoreMediaData changes
        setupObservers()
        // Set the intial state of the lock
        updateLock()
    }
    
    func setupObservers() {
        videoInputStatusObserver?.invalidate()
        audioInputStatusObserver?.invalidate()
        
        guard let movieOutput = synchronizedMovieOutput else { return }
        
        videoInputStatusObserver = movieOutput.assetWriterVideoInput.observe(\.isReadyForMoreMediaData, options: [.new, .old]) { [weak self] (assetWriterVideoInput, change) in
            guard let weakSelf = self else {
                return
            }
            weakSelf.updateLock()
        }
        audioInputStatusObserver = movieOutput.assetWriterAudioInput?.observe(\.isReadyForMoreMediaData, options: [.new, .old]) { [weak self] (assetWriterAudioInput, change) in
            guard let weakSelf = self else {
                return
            }
            weakSelf.updateLock()
        }
    }
    
    func updateLock() {
        guard let movieOutput = synchronizedMovieOutput else {
            return
        }
        
        conditionLock.lock()
        // Allow reading if either input is able to accept data, prevent reading if both inputs are unable to accept data.
        if(movieOutput.assetWriterVideoInput.isReadyForMoreMediaData || movieOutput.assetWriterAudioInput?.isReadyForMoreMediaData ?? false) {
            readingShouldWait = false
            conditionLock.signal()
        }
        else {
            readingShouldWait = true
        }
        conditionLock.unlock()
    }
    
    // MARK: -
    // MARK: Thread configuration
    
    func configureThread() {
        let clock2abs = Double(timebaseInfo.denom) / Double(timebaseInfo.numer) * Double(NSEC_PER_MSEC)
        
        // http://docs.huihoo.com/darwin/kernel-programming-guide/scheduler/chapter_8_section_4.html
        //
        // To see the impact of adjusting these values, uncomment the print statement above mach_wait_until() in self.readNextVideoFrame()
        //
        // Setup for 5 ms of work.
        // The anticpated frame render duration is in the 1-3 ms range on an iPhone 6 for 1080p without filters and 1-7 ms range with filters
        // If the render duration is allowed to exceed 16ms (the duration of a frame in 60fps video)
        // the 60fps video will no longer be playing in real time.
        let computation = UInt32(5 * clock2abs)
        // Tell the scheduler the next 20 ms of work needs to be done as soon as possible.
        let period      = UInt32(0 * clock2abs)
        // According to the above scheduling chapter this constraint only appears relevant
        // if preemtible is set to true and the period is not 0. If this is wrong, please let me know.
        let constraint  = UInt32(5 * clock2abs)
        
        //print("period: \(period) computation: \(computation) constraint: \(constraint)")
        
        let THREAD_TIME_CONSTRAINT_POLICY_COUNT = mach_msg_type_number_t(MemoryLayout<thread_time_constraint_policy>.size / MemoryLayout<integer_t>.size)
        
        var policy = thread_time_constraint_policy()
        var ret: Int32
        let thread: thread_port_t = pthread_mach_thread_np(pthread_self())
        
        policy.period = period
        policy.computation = computation
        policy.constraint = constraint
        policy.preemptible = 0
        
        ret = withUnsafeMutablePointer(to: &policy) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(THREAD_TIME_CONSTRAINT_POLICY_COUNT)) {
                thread_policy_set(thread, UInt32(THREAD_TIME_CONSTRAINT_POLICY), $0, THREAD_TIME_CONSTRAINT_POLICY_COUNT)
            }
        }
        
        if ret != KERN_SUCCESS {
            mach_error("thread_policy_set:", ret)
            print("Unable to configure thread")
        }
    }
    
    func nanosToAbs(_ nanos: UInt64) -> UInt64 {
        return nanos * UInt64(timebaseInfo.denom) / UInt64(timebaseInfo.numer)
    }
    
    func synchronizedEncodingDebugPrint(_ string: String) {
        if(synchronizedMovieOutput != nil && synchronizedEncodingDebug) {
            print(string)            
        }
    }
}

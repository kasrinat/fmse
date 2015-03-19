package com.streamroot {

import flash.external.ExternalInterface;
import flash.net.NetStream;
import flash.net.NetStreamAppendBytesAction;

//import flash.events.TimerEvent;
import flash.events.Event;

import flash.system.Worker;
import flash.system.WorkerDomain;
import flash.system.MessageChannel;
import flash.system.WorkerState;

/*import com.dash.handlers.InitializationAudioSegmentHandler;
import com.dash.handlers.InitializationVideoSegmentHandler;
import com.dash.handlers.VideoSegmentHandler;
import com.dash.handlers.AudioSegmentHandler;*/

import com.dash.boxes.Muxer;

import com.dash.utils.Base64;

import flash.utils.ByteArray;
import flash.utils.setTimeout;
import flash.utils.Timer;
import flash.utils.getQualifiedClassName;

import com.streamroot.IStreamrootInterface;
import com.streamroot.StreamrootInterfaceBase;
import com.streamroot.StreamBuffer;
import com.streamroot.Segment;
import com.streamroot.Transcoder;
import com.streamroot.HlsSegmentValidator;

import com.streamroot.util.TrackTypeHelper;
import com.streamroot.util.TranscoderHelper;
import com.streamroot.util.Conf;

public class StreamrootMSE {

    private var _streamrootInterface:IStreamrootInterface;
    
    private var _streamBuffer:StreamBuffer;
    
    private var _muxer:Muxer;
    
    private var _loaded:Boolean = false;
    
//    private var _initHandlerAudio:InitializationAudioSegmentHandler;
//    private var _initHandlerVideo:InitializationVideoSegmentHandler;

    private var _seek_offset:Number = 0;

    //private var _buffered:uint = 0;
    //private var _buffered_audio:uint = 0;

    /*private var _pendingOffsetVideo:Number;
    private var _pendingOffsetAudio:Number;

    private var _pendingTimestampVideo:Number;
    private var _pendingTimestampAudio:Number;

    private var _pendingIsInitVideo:Boolean;
    private var _pendingIsInitAudio:Boolean;

    private var _pendingDataVideo:String = "";
    private var _pendingDataAudio:String = "";

    private var _readPositionVideo:uint;
    private var _readPositionAudio:uint;

    private var _decodedDataVideo:ByteArray = new ByteArray();
    private var _decodedDataAudio:ByteArray = new ByteArray();

    private var _decodedCompleteVideo : Boolean = false;
    private var _decodedCompleteAudio : Boolean = false;

    private static const TIMER_IDLE : String = "Idle";
    private static const TIMER_REQUESTING : String = "Requesting";
    private static const TIMER_ACTIVE : String = "Active";

    private var _timerVideo:Timer;
    private var _timerAudio:Timer;

    private var _timerStateVideo:String = TIMER_IDLE;
    private var _timerStateAudio:String = TIMER_IDLE;

    private static const DECODE_CHUNK_SIZE : uint = 64 * 1024;
    private static const DECODE_INTERVAL : uint = 0;*/

    private static const TIMEOUT_LENGTH:uint = 5;


    [Embed(source="TranscodeWorker.swf", mimeType="application/octet-stream")]
    private static var WORKER_SWF:Class;

    private var _worker:Worker;

    private var _mainToWorker:MessageChannel;
    private var _workerToMain:MessageChannel;
    private var _commChannel:MessageChannel;

    private var _isWorkerReady:Boolean = false;

    private var _isWorkerBusy:Boolean = false;
    private var _pendingAppend:Object;
    private var _discardAppend:Boolean = false; //Used to discard data from worker in case we were seeking during transcoding

    private var _hlsSegmentValidator:HlsSegmentValidator;




    public function StreamrootMSE(streamrootInterface:IStreamrootInterface) {
        _streamrootInterface = streamrootInterface;

        _muxer = new Muxer();
        _hlsSegmentValidator = new HlsSegmentValidator(this);
		
		//StreamrootMSE callbacks
        ExternalInterface.addCallback("addSourceBuffer", addSourceBuffer);
        ExternalInterface.addCallback("appendBuffer", appendBuffer);
        //ExternalInterface.addCallback("buffered", buffered);
        
        //StreamBuffer callbacks
        ExternalInterface.addCallback("remove", remove);
        
        //StreamrootInterface callbacks
        //METHODS
        ExternalInterface.addCallback("onMetaData", onMetaData);
        ExternalInterface.addCallback("play", play);
        ExternalInterface.addCallback("pause", pause);
        ExternalInterface.addCallback("stop", stop);
        ExternalInterface.addCallback("seek", seek);
        ExternalInterface.addCallback("bufferEmpty", bufferEmpty);
        ExternalInterface.addCallback("onTrackList", onTrackList);
        //GETTERS
        ExternalInterface.addCallback("currentTime", currentTime);
        ExternalInterface.addCallback("paused", paused);
        
        _streamBuffer = new StreamBuffer(this);

        setupWorker();
    }

    private function setupWorker():void {
        var workerBytes:ByteArray = new WORKER_SWF() as ByteArray;
        _worker = WorkerDomain.current.createWorker(workerBytes);

        // Send to worker
        _mainToWorker = Worker.current.createMessageChannel(_worker);
        _worker.setSharedProperty("mainToWorker", _mainToWorker);

        // Receive from worker
        _workerToMain = _worker.createMessageChannel(Worker.current);
        _workerToMain.addEventListener(Event.CHANNEL_MESSAGE, onWorkerToMain);
        _worker.setSharedProperty("workerToMain", _workerToMain);

        // Receive startup message from worker
        _commChannel = _worker.createMessageChannel(Worker.current);
        _commChannel.addEventListener(Event.CHANNEL_MESSAGE, onCommChannel);
        _worker.setSharedProperty("commChannel", _commChannel);

        _worker.start();
    }

    public function setSeekOffset(timeSeek:Number):void {
        debug("Set seek offset", this);
        _seek_offset = timeSeek;

        //_buffered = timeSeek*1000000;
        //_buffered_audio = timeSeek*1000000;
        
        // Set isSeeking to skip _previousPTS check in HlsSegmentValidator.as
        _hlsSegmentValidator.setIsSeeking(true);

        if (_pendingAppend) {
            //remove pending append job to avoid appending it after seek
            debug("Discarding _pendingAppend " + _pendingAppend.type, this);
            sendSegmentFlushedMessage(_pendingAppend.type);
            _pendingAppend = null;
        }

        //If worker is appending a segment during seek, discard it as we don't want to append it
        if (_isWorkerBusy) {
            debug("Setting discard to true", this);
            _discardAppend = true
        }
        _streamBuffer.onSeek();
        _mainToWorker.send('seeking');
    }

    private function addSourceBuffer(type:String):void {
        var key:String = TrackTypeHelper.getType(type);
        if(key){
            _streamBuffer.addSourceBuffer(key);            
        }else{
            error("Error: Type not supported: " + type);
        }
    }

    //timestampStart and timestampEnd in second
    private function appendBuffer(data:String, type:String, isInit:Boolean, startTime:Number = 0, endTime:Number = 0 ):void {
        debug("AppendBuffer", this);
        var message:Object = {data: data, type: type, isInit: isInit, startTime: startTime, endTime: endTime, offset: _seek_offset};// - offset + 100};
        appendOrQueue(message);


        /*
        if (isInit) {
            _transcoder.transcodeInit(data, type);
            if (type.indexOf("audio") >= 0) {
                ExternalInterface.call("sr_flash_updateend_audio");
            } else if (type.indexOf("video") >= 0) {
                ExternalInterface.call("sr_flash_updateend_video");
            } else {
                error("no type matching");
            }
        } else {

            var offset = _seek_offset * 1000;

            var segmentBytes = _transcoder.transcode(data, type, timestamp - offset);

            _streamrootInterface.appendBuffer(segmentBytes)


            //Check better way to check type here as well
            if (type.indexOf("audio") >= 0) {
                _hasAudio = true;
                ExternalInterface.call("sr_flash_updateend_audio");
            } else if (type.indexOf("video") >= 0) {
                _hasVideo = true;
                ExternalInterface.call("sr_flash_updateend_video");
            } else {
                error("no type matching");
            }
        }
        */

        /*
        var timestamp:Number = 0;
        var buffered:uint = 0;
        if (!isInit) {
            timestamp = Number(args[3]);
            buffered = int(args[4]);
        }
        asyncAppend(data, type, isInit, timestamp, buffered);
        */
    }

    private function appendOrQueue(message:Object):void {
        if (!_isWorkerBusy) {
            _isWorkerBusy = true;
            setTimeout(sendWorkerMessage, TIMEOUT_LENGTH, message);
            //_mainToWorker.send(message);
        } else if (!_pendingAppend) {
            _pendingAppend = message; //TODO: clear this job when we seek
        } else {
            error("Error: not supporting more than one pending job for now", this);
            sendSegmentFlushedMessage(message.type);
        }
    }

    private function sendWorkerMessage():void {
        _mainToWorker.send(arguments[0]);
    }
    
    /*private function asyncAppend(data:String, type:String, isInit:Boolean, timestamp:Number = 0, buffered:uint = 0):void {
        //var bytes_event:ByteArray = Base64.decode(data);

        debug("ASYNC APPEND");

        var offset :Number = _seek_offset * 1000;

        if (type.indexOf("audio") >= 0){
            _pendingOffsetAudio = offset;
            _pendingIsInitAudio = isInit;
            _pendingDataAudio = data;

            if (!isInit) {
                _pendingTimestampAudio = timestamp;
                _buffered_audio = buffered; //TODO: should remove buffered from flash
            }

            //_pendingDataAudio = "";
            //_decodedDataAudio = new ByteArray();
            //_readPositionAudio = 0;

            if (_timerStateVideo !== TIMER_ACTIVE) {
                startTimerAudio();
            } else {
                _timerStateAudio = TIMER_REQUESTING;
            }

        } else if (type.indexOf("video") >= 0) {
            _pendingOffsetVideo = offset;
            _pendingIsInitVideo = isInit;
            _pendingDataVideo = data;

            if (!isInit) {
                _pendingTimestampVideo = timestamp;
                _buffered = buffered; //TODO: should remove buffered from flash
            }

            //_pendingDataVideo = "";
            //_decodedDataVideo = new ByteArray();
            //_readPositionVideo = 0;
            if (_timerStateAudio !== TIMER_ACTIVE) {
                startTimerVideo();
            } else {
                _timerStateVideo = TIMER_REQUESTING;
            }
        }
    }

    private function startTimerAudio():void {
        _timerStateAudio = TIMER_ACTIVE;
        _timerAudio = new Timer (DECODE_INTERVAL, 0);
        _timerAudio.addEventListener(TimerEvent.TIMER, decodeAudio);
        _timerAudio.start();
    }

    private function startTimerVideo():void {
        _timerStateVideo = TIMER_ACTIVE;
        _timerVideo = new Timer (DECODE_INTERVAL, 0);
        _timerVideo.addEventListener(TimerEvent.TIMER, decodeVideo);
        _timerVideo.start();
    }

    private function decodeAudio(e : Event):void {
        if (_decodedCompleteAudio) {
            _timerAudio.stop();

            appendAudio(_decodedDataAudio);

            _pendingDataAudio = "";
            _decodedDataAudio = new ByteArray();
            //_decodedDataAudio.position = 0;
            _readPositionAudio = 0;
            _decodedCompleteAudio = false
        } else {
            var beginTS:Number = new Date().valueOf();

            var startPos : uint = _readPositionAudio;
            var endPos : uint;

            if (_pendingDataAudio.length <= startPos + DECODE_CHUNK_SIZE) {
                endPos = _pendingDataAudio.length;
                _decodedCompleteAudio = true;
            } else {
                endPos = startPos + DECODE_CHUNK_SIZE;
            }
            var tmpString : String = _pendingDataAudio.substring(startPos, endPos);
            _decodedDataAudio.writeBytes(Base64.decode(tmpString));

            _readPositionAudio = endPos;

            var decodedTS:Number = new Date().valueOf();
            var decoded:Number = decodedTS - beginTS;
            debug('DECODED (ms): ' + decoded);
        }
    }

    private function decodeVideo(e : Event):void {
        if (_decodedCompleteVideo) {
            _timerVideo.stop();

            appendVideo(_decodedDataVideo);

            _pendingDataVideo = "";
            _decodedDataVideo = new ByteArray();
            _readPositionVideo = 0;
            _decodedCompleteVideo = false;
        } else {
            var beginTS:Number = new Date().valueOf();

            var startPos : uint = _readPositionVideo;
            var endPos : uint;

            if (_pendingDataVideo.length <= startPos + DECODE_CHUNK_SIZE) {
                endPos = _pendingDataVideo.length;
                _decodedCompleteVideo = true;
            } else {
                endPos = startPos + DECODE_CHUNK_SIZE;
            }
            var tmpString : String = _pendingDataVideo.substring(startPos, endPos);
            _decodedDataVideo.writeBytes(Base64.decode(tmpString));

            _readPositionVideo = endPos;


            var decodedTS :Number = new Date().valueOf();
            var decoded :Number = decodedTS - beginTS;
            debug('DECODED (ms): ' + decoded);
        }
    }

    private function appendAudio(bytes_event:ByteArray):void {
        if(_pendingIsInitAudio==true){
            _initHandlerAudio = new InitializationAudioSegmentHandler(bytes_event);
        } else {
            var decodedTS :Number = new Date().valueOf();

            var bytes_append_audio:ByteArray = new ByteArray();
            var audioSegmentHandler:AudioSegmentHandler = new AudioSegmentHandler(bytes_event, _initHandlerAudio.messages, _initHandlerAudio.defaultSampleDuration, _initHandlerAudio.timescale, _pendingTimestampAudio - _pendingOffsetAudio, _muxer);
            bytes_append_audio.writeBytes(audioSegmentHandler.bytes);

            if (_isWorkerReady){
                _mainToWorker.send(true)
            }


            var transcodedTS:Number = new Date().valueOf();
            var transcoded:Number = transcodedTS - decodedTS;
            debug('TRANSCODED (ms): ' + transcoded);

            _streamrootInterface.appendBuffer(bytes_append_audio);

            var appendedTS:Number = new Date().valueOf();
            var appended:Number = appendedTS - transcodedTS;
            debug('APPENDED (ms): ' + appended);

            setHasData(true, AUDIO);
        }

        //Set audio timer state to idle and start timer video if it was waiting
        _timerStateAudio = TIMER_IDLE;
        if (_timerStateVideo === TIMER_REQUESTING) {
            startTimerVideo();
        }

        ExternalInterface.call("sr_flash_updateend_audio");
        return;
    }

    private function appendVideo(bytes_event:ByteArray):void {
        if(_pendingIsInitVideo==true){
            _initHandlerVideo = new InitializationVideoSegmentHandler(bytes_event);
        }else{
            var decodedTS :Number = new Date().valueOf();

            var bytes_append:ByteArray = new ByteArray();
            var videoSegmentHandler:VideoSegmentHandler = new VideoSegmentHandler(bytes_event, _initHandlerVideo.messages, _initHandlerVideo.defaultSampleDuration, _initHandlerVideo.timescale, _pendingTimestampVideo - _pendingOffsetVideo, _muxer);
            bytes_append.writeBytes(videoSegmentHandler.bytes);

            if (_isWorkerReady){
                _mainToWorker.send(true)
            }

            var transcodedTS:Number = new Date().valueOf();
            var transcoded:Number = transcodedTS - decodedTS;
            debug('TRANSCODED (ms): ' + transcoded);

            _streamrootInterface.appendBuffer(bytes_append)

            var appendedTS:Number = new Date().valueOf();
            var appended:Number = appendedTS - transcodedTS;
            debug('APPENDED (ms): ' + appended);

            //debug('media appended');
            setHasData(true, VIDEO);
        }

        //Set video timer state to idle and start timer audio if it was waiting
        _timerStateVideo = TIMER_IDLE;
        if (_timerStateAudio === TIMER_REQUESTING) {
            startTimerAudio();
        }

        ExternalInterface.call("sr_flash_updateend_video");
        return;
    }*/

    /*private function buffered(type:String):Number{
            if (type.indexOf("audio") >= 0){
                return _buffered_audio;
            }
            if (type.indexOf("video") >= 0){
                return _buffered;
            }
            return _buffered;
    }*/

    public function getFileHeader():ByteArray {
        var output:ByteArray = new ByteArray();
        output.writeByte(0x46); // 'F'
        output.writeByte(0x4c); // 'L'
        output.writeByte(0x56); // 'V'
        output.writeByte(0x01); // version 0x01

        var flags:uint = 0;

        flags |= 0x01;

        output.writeByte(flags);

        var offsetToWrite:uint = 9; // minimum file header byte count

        output.writeUnsignedInt(offsetToWrite);

        var previousTagSize0:uint = 0;

        output.writeUnsignedInt(previousTagSize0);

        return output;
    }

    public function appendFileHeader(ns:NetStream):void {
        var flv_header:ByteArray = this.getFileHeader();
        ns.appendBytesAction(NetStreamAppendBytesAction.RESET_BEGIN);
        ns.appendBytes(flv_header);
    }

    private function onWorkerToMain(event:Event):void {
        var message:* = _workerToMain.receive();

        var type:String = message.type;
        var isInit:Boolean = message.isInit;
        var min_pts:Number = message.min_pts;//second
        var max_pts:Number = message.max_pts;//second
        var startTime:Number = message.startTime;
        
		var segment:Segment = new Segment(message.segmentBytes, message.type, message.startTime, message.endTime);
        
		_isWorkerBusy = false;

        if (!_discardAppend) {

            if (!isInit) {
                // CLIEN-19: check if it's the right hls segment before appending it. 
                
                if (TrackTypeHelper.isHLS(segment.type)) {
                    var previousPTS:Number = _streamBuffer.getBufferEndTime();
                    var segmentChecked:String = _hlsSegmentValidator.checkSegmentPTS(min_pts, max_pts, startTime, previousPTS);
				}
                
                if (TrackTypeHelper.isHLS(segment.type) && TranscoderHelper.isPTSError(segmentChecked)) {
                    // We just call an error that will discard the segment and send an updateend with error:true and min_pts to download the right segment
                    debug("Timestamp and min_pts don't match", this)
                    sendSegmentFlushedMessage(TranscoderHelper.PTS_ERROR, min_pts, max_pts);
                    return;
                } else if (TrackTypeHelper.isHLS(segment.type) && TranscoderHelper.isPreviousPTSError(segmentChecked)) {
                    // No need to send back min and max pts in this case since media map doesn't need to be updated
                    debug("previousPTS and min_pts don't match", this)
                    sendSegmentFlushedMessage(TranscoderHelper.PREVIOUS_PTS_ERROR);
                    return;
                } else {
                    // Append DASH || Smooth || Validated HLS segment
                    CONFIG::LOGGING_PTS {
                        debug("Appending segment in StreamBuffer", this);
                    }
	                _streamBuffer.appendSegment(segment, TrackTypeHelper.getType(segment.type));
				}
            }

            if (_pendingAppend) {
                debug("Unqueing", this);
                appendOrQueue(_pendingAppend);
                _pendingAppend = null;
            }


            if (TrackTypeHelper.isHLS(type)) {
                _hlsSegmentValidator.setIsSeeking(false);
                setTimeout(updateendVideoHls, TIMEOUT_LENGTH, min_pts, max_pts);
            } else if (TrackTypeHelper.isAudio(type)) {
                setTimeout(updateendAudio, TIMEOUT_LENGTH);
            } else if (TrackTypeHelper.isVideo(type)) {
                setTimeout(updateendVideo, TIMEOUT_LENGTH);
            } else {
                error("no type matching");
            }
        } else {
            sendSegmentFlushedMessage(type);
            _discardAppend = false;
        }
    }

    private function sendSegmentFlushedMessage(type:String, min_pts:Number = 0, max_pts:Number = 0):void {
        CONFIG::LOGGING {
            debug("Discarding segment    " + type, this);
        }
        if(TranscoderHelper.isPTSError(type)) {
            CONFIG::LOGGING_PTS {
                debug("sendSegmentFlushedMessage min_pts: " + min_pts, this);
                debug("sendSegmentFlushedMessage max_pts: " + max_pts, this);
            }
            setTimeout(updateendVideoHls, TIMEOUT_LENGTH, min_pts, max_pts, true);
        } else if (TrackTypeHelper.isHLS(type)) {    // This case includes PREVIOUS_PTS_ERROR case
            CONFIG::LOGGING_PTS {
                debug("Inside case discarding but no min/max pts returned to js", this);
            }
            setTimeout(updateendVideo, TIMEOUT_LENGTH, true);
        } else if (TrackTypeHelper.isAudio(type)) {
            setTimeout(updateendAudio, TIMEOUT_LENGTH, true);
        } else if (TrackTypeHelper.isVideo(type)) {
            setTimeout(updateendVideo, TIMEOUT_LENGTH, true);
        }
    }

    private function updateendVideoHls(min_pts:Number, max_pts:Number, error:Boolean = false):void {
        CONFIG::LOGGING_PTS {
            debug("updateendVideoHls min_pts: " + min_pts, this);
            debug("updateendVideoHls max_pts: " + max_pts, this);
        }
        ExternalInterface.call("sr_flash_updateend_video", error, min_pts, max_pts);
    }

    private function updateendAudio(error:Boolean = false):void {
        ExternalInterface.call("sr_flash_updateend_audio", error);
    }

    private function updateendVideo(error:Boolean = false):void {
        ExternalInterface.call("sr_flash_updateend_video", error);
    }

    private function onCommChannel(event:Event):void {
        var message:* = _commChannel.receive();
        _isWorkerReady = true;

        if (message.command == "debug") {
            debug(message.message, this);
        } else if (message.command == "error") {
            transcodeError(message.message);
            flush(message);
        }
    }
    
    //StreamBuffer function
    public function appendNetStream(bytes:ByteArray):void {
        _streamrootInterface.appendBytes(bytes);
    }
    
    public function remove(start:Number, end:Number, type:String):Number {
        return _streamBuffer.removeDataFromSourceBuffer(start, end, TrackTypeHelper.getType(type));
    }
    
    public function getBufferLength():Number{
        return _streamrootInterface.getBufferLength();
    }
        
    //StreamrootInterface function   
    private function onMetaData(duration:Number, width:Number=0, height:Number=0):void {
        _streamrootInterface.onMetaData(duration, width, height);
    }
    
    private function play():void {
        _streamrootInterface.play();
    }
    
    private function pause():void {
        _streamrootInterface.pause();
    }
    
    private function stop():void {
        _streamrootInterface.stop();
    }
    
    private function seek(time:Number):void {
        _streamrootInterface.seek(time);
    }
    
    private function currentTime():Number {
        return _streamrootInterface.currentTime();
    }
        
    private function paused():Boolean {
        return _streamrootInterface.paused();
    }
    
    public function bufferEmpty():void {
        _streamrootInterface.bufferEmpty();
        triggerWaiting();
    }
    
    public function bufferFull():void {
        _streamrootInterface.bufferFull();
        triggerPlaying();
    }
    
    private function onTrackList(trackList:String):void {
        _streamrootInterface.onTrackList(trackList);
    }
    
    public function loaded():void {
        //append the FLV Header to the provider, using appendBytesAction
        _streamrootInterface.appendBytesAction(NetStreamAppendBytesAction.RESET_BEGIN);
        _streamrootInterface.appendBytes(getFileHeader());
        
        if (!_loaded) {
            //Call javascript callback (implement window.sr_flash_ready that will initialize our JS library)
            //Do not call on replay, as it would initialize a second instance of our JS library (that's why the
            //_loaded Boolean is for here)
            ExternalInterface.call('sr_flash_ready');
            _loaded = true;
        }
        
        //Tell our Javascript library to start loading video segments
        triggerLoadStart();
    }
    
    //StreamrootInterface events
    public function triggerSeeked():void {
        //Trigger event when seek is done. Not used for now
        ExternalInterface.call("sr_flash_seeked");
    }
    
    public function triggerLoadStart():void {
        //Trigger event when we want to start loading data (at the beginning of the video or on replay)
        ExternalInterface.call("sr_flash_loadstart");
    }
    
    public function triggerPlay():void {
        //Trigger event when video starts playing. Not used for now
        ExternalInterface.call("sr_flash_play");
    }
    
    public function triggerPlaying():void {
        //Trigger event when video starts playing. Not used for now
        ExternalInterface.call("sr_flash_playing");
    }
    
    public function triggerWaiting():void {
        //Trigger event when video starts playing. Not used for now
        ExternalInterface.call("sr_flash_waiting");
    }
    
    public function triggerStopped():void {
        //Trigger event when video ends.
        ExternalInterface.call("sr_flash_stopped");
    }
    
    public function error(message:Object, obj:Object = null):void {
        if (Conf.LOG_ERROR) {
            if(obj != null){
                var textMessage:String = getQualifiedClassName(obj) + ".as : " + String(message);
                ExternalInterface.call("console.error", textMessage);
            }else{
                ExternalInterface.call("console.error", String(message));
            }
        }
    }
    
    public function transcodeError(message:Object):void{
        ExternalInterface.call("sr_flash_transcodeError", String(message));
    }
    
    public function debug(message:Object, obj:Object = null):void {
        if (Conf.LOG_DEBUG) {
            if(obj != null){
                var textMessage:String = getQualifiedClassName(obj) + ".as : " + String(message);
                ExternalInterface.call("console.debug", textMessage);
            }else{
                ExternalInterface.call("console.debug", String(message));
            }
        }
    } 
    
    public function flush(message:Object):void{
        if(message.type){
            //If worker sent back an attribute "type", we want to set _isWorkerBusy to false and trigger
            //a segment flushed message to notify the JS that append didn't work well, in order not to
            //block the append pipeline
            _isWorkerBusy = false;
            debug("Error type: " + message.type, this);
            sendSegmentFlushedMessage(message.type);
        }
    }  
}
}

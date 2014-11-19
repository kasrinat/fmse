package com.streamroot {

import com.dash.utils.Base64;
import flash.utils.ByteArray;

import com.dash.handlers.InitializationAudioSegmentHandler;
import com.dash.handlers.InitializationVideoSegmentHandler;
import com.dash.handlers.VideoSegmentHandler;
import com.dash.handlers.AudioSegmentHandler;

import com.hls.HTTPStreamingMP2TSFileHandler;

import com.dash.boxes.Muxer;

public class Transcoder {

	  private var _initHandlerAudio:InitializationAudioSegmentHandler;
    private var _initHandlerVideo:InitializationVideoSegmentHandler;

    private var _muxer:Muxer;
		private var _httpstreamingMP2TSFileHandler:HTTPStreamingMP2TSFileHandler;

	public function Transcoder() {
        _muxer = new Muxer();
		_httpstreamingMP2TSFileHandler = new HTTPStreamingMP2TSFileHandler();
	}

	//TODO: transcode init in separate method (problem with return type?), return bytes to worker, that will send message back to MSE.
	//Call this method from MSE instead of fake Async with loop ( keep that on the side in different class)
	//We might want to take turns between appending audio and video though (if argument problems, or if simplifies the workflow)
    //timestamp must already take seek offset into account

    public function transcodeInit(data:String, type:String):void {
        var bytes_event:ByteArray = Base64.decode(data);
        if (isAudio(type)) {
            _initHandlerAudio = new InitializationAudioSegmentHandler(bytes_event);
        } else if (isVideo(type)) {
            _initHandlerVideo = new InitializationVideoSegmentHandler(bytes_event);
        }
        //TODO: switch for HLS + send error if no matching type
    }

	public function transcode(data:String, type:String, timestamp:Number, offset:Number):ByteArray {
		var bytes_event:ByteArray = Base64.decode(data);


        if (isHls(type)) {
            if (!_httpstreamingMP2TSFileHandler) {
                _httpstreamingMP2TSFileHandler = new HTTPStreamingMP2TSFileHandler();
            }
					var bytes_append:ByteArray = new ByteArray();
					bytes_event.position = 0;
					bytes_append.writeBytes(_httpstreamingMP2TSFileHandler.processFileSegment_bigger(bytes_event,offset));
					return bytes_append
		  }else if(isAudio(type)){
            var bytes_append_audio:ByteArray = new ByteArray();
            var audioSegmentHandler:AudioSegmentHandler = new AudioSegmentHandler(bytes_event, _initHandlerAudio.messages, _initHandlerAudio.defaultSampleDuration, _initHandlerAudio.timescale, timestamp - offset + 100, _muxer);
            bytes_append_audio.writeBytes(audioSegmentHandler.bytes);

            return bytes_append_audio;
        } else /*if (isVideo(type))*/ {
            var bytes_append:ByteArray = new ByteArray();
            var videoSegmentHandler:VideoSegmentHandler = new VideoSegmentHandler(bytes_event, _initHandlerVideo.messages, _initHandlerVideo.defaultSampleDuration, _initHandlerVideo.timescale, timestamp - offset + 100, _muxer);
            bytes_append.writeBytes(videoSegmentHandler.bytes);

            return bytes_append;
        }
        //TODO: switch for HLS + send error if no matching type
	}

    public function seeking():void {
        _httpstreamingMP2TSFileHandler = undefined;
    }

    private function isAudio(type:String):Boolean {
        return type.indexOf("audio") >= 0;
    }

    private function isVideo(type:String):Boolean {
        return type.indexOf("video") >= 0;
    }

		private function isHls(type:String):Boolean {
				return type.indexOf("apple") >= 0;
		}




}


}
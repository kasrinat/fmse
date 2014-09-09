"use strict";

var SourceBuffer = require('./SourceBuffer');

var MediaSourceFlash = function (videoExtension) {
	var	self = this,
        
        _videoExtension = videoExtension,
        
        _swfobj = _videoExtension.getSwf(),
        
        _READY_STATE = {
            OPEN: 'open',
            CLOSED: 'closed'
        },
        
        _readyState = _READY_STATE.CLOSED,
            
        //TODO: is duration realy an attribute of MSE, or of video?
		_duration = 0,
        
		_listeners = [],
        
		_sourceBuffers= [],
        
		_addEventListener = function(type, listener){
			if (!_listeners[type]){
				_listeners[type] = [];
			}
			_listeners[type].unshift(listener);
		},
        
		_removeEventListener = function(type, listener){
            //TODO: I don't think that works. Why return? Should transform _listeners property of this class. UPDATE: see comment in SourceBuffer. Shouldn't the event bus be a class on its own?
			var listeners = _listeners[type],
				i = listeners.length;
			while (i--) {
				if (listeners[i] === listener) {
					return listeners.splice(i, 1);
				}
			}
		},
        
		_trigger = function(event){
			//updateend, updatestart
			var listeners = _listeners[event.type] || [],
				i = listeners.length;
			while (i--) {
				listeners[i](event);
			}
		},
        
		_addSourceBuffer = function(type){
			var sourceBuffer;
			sourceBuffer = new SourceBuffer(self, type, _swfobj);
			_sourceBuffers.push(sourceBuffer);
			_videoExtension.registerSourceBuffer(sourceBuffer);
			return sourceBuffer;
		},
            
		_removeSourceBuffer = function(){
            
        },
            
		_endOfStream =  function(){
            
        },
        /*
		_initCallback = function (e){
			_swfobj = e.ref;
            
			console.log('\n\n\n\n\nSWFOBJECT DONE');
		},
        */
        
		_initialize = function(){
            //var pluginPlayer_path = 'pluginPlayer_100_jsdata.swf';
            
            _videoExtension.createSrc(self);
            
            //TODO: for VJS, flash is already ready, shouldn't need a timeout
            setTimeout(function() {_readyState = _READY_STATE.OPEN;}, 100);
            
            /*
            window.sr_flash_player_ready = function () {
                _readyState = _READY_STATE.OPEN;
                _videoExtension.createSrc(_swfobj, self);
            };
            */
			 
			//swfobject.embedSWF("pluginPlayer.swf", "video", "100%", "100%", "10.0.0", false, false, false, false, initCallback);
			//console.log('\n\n\n\n\nPLUGIN PLAYER PATH');
			//console.log(pluginPlayer_path)
            //var pluginPlayer_path = 'pluginPlayer_100_jsdata.swf';
			//swfobject.embedSWF(pluginPlayer_path, "video_flash", "100%", "500", "10.0.0", false, false, false, false, _initCallback);
			//to trigger when the flash shim is loaded
			//this.trigger({{type:'sourceopen'}})
        };
    
    this.addSourceBuffer = function (type) {
        return _addSourceBuffer(type);
    };
    
    this.addEventListener = function (type, listener) {
        _addEventListener(type, listener);
    };
    
    this.trigger = function (event) {
        _trigger(event);
    };
    
    
    Object.defineProperty(this, "readyState", {
        get: function () { return _readyState; },
        set: undefined
    });
    
    _initialize();
};

module.exports = MediaSourceFlash;
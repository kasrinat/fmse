

package com.dash.handlers {
import com.dash.boxes.FLVTag;
import com.dash.boxes.Muxer;
import com.dash.boxes.NalUnit;

import flash.utils.ByteArray;

public class VideoSegmentHandler extends MediaSegmentHandler {
    private static var _nalUnit:NalUnit = new NalUnit(); //TODO inject

    private static const MIN_CTO:int = -33;

    public function VideoSegmentHandler(segment:ByteArray, messages:Vector.<FLVTag>, defaultSampleDuration:uint,
                                        timescale:uint, timestamp:Number, mixer:Muxer) {
        super(segment, messages, defaultSampleDuration, timescale, timestamp, mixer);
    }

    protected override function buildMessage(sampleDuration:uint, sampleSize:uint, sampleDependsOn:uint,
                                             sampleIsDependedOn:uint, compositionTimeOffset:Number,
                                             dataOffset:uint, ba:ByteArray):FLVTag {
        var message:FLVTag = new FLVTag();

        message.markAsVideo();

        message.timestamp = _timestamp;
        _timestamp = message.timestamp + sampleDuration * 1000 / _timescale;

        message.duration     = sampleDuration *1000*1000  / _timescale;

        message.length = sampleSize;

        message.dataOffset = dataOffset;

        message.data = new ByteArray();
        ba.position = message.dataOffset;
        ba.readBytes(message.data, 0, sampleSize);

        if (sampleDependsOn == 2) {
            message.frameType = FLVTag.I_FRAME;
        } else if (sampleDependsOn == 1 && sampleIsDependedOn == 1) {
            message.frameType = FLVTag.P_FRAME;
        } else if (sampleDependsOn == 1 && sampleIsDependedOn == 2) {
            message.frameType = FLVTag.B_FRAME;
        } else {
            message.frameType = _nalUnit.parse(message.data);
        }

        if (!isNaN(compositionTimeOffset)) {
            message.compositionTimestamp = compositionTimeOffset * 1000 / _timescale - MIN_CTO;
        }

        return message;
    }

}
}

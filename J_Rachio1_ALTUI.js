//# sourceURL=J_Rachio1_ALTUI.js
/** 
 * J_Rachio1_ALTUI.js
 * Special presentation for ALTUI for Rachio1
 *
 * Copyright 2016,2017 Patrick H. Rigney, All Rights Reserved.
 * This file is part of Reactor. For license information, see LICENSE at https://github.com/toggledbits/Reactor
 */
/* globals $,MultiBox,ALTUI_PluginDisplays,_T */

"use strict";

var Rachio1_ALTUI = ( function( window, undefined ) {

    function _getStyle() {
        var style = "";
        return style;
    }
    
    function _servicedraw( device ) {
            var html ="";
            var message = MultiBox.getStatus( device, "urn:toggledbits-com:serviceId:Rachio1", "Message");
            html += '<div>' + message + '</div>';
            return html;
    }
    
    function _devicedraw( device ) {
            var html ="";
            var message = MultiBox.getStatus( device, "urn:toggledbits-com:serviceId:RachioDevice1", "Message");
            var ready = MultiBox.getStatus( device, "urn:toggledbits-com:serviceId:RachioDevice1", "On");
            var watering = MultiBox.getStatus( device, "urn:toggledbits-com:serviceId:RachioDevice1", "Watering");
            html += '<div>' + message + '</div>';
            html += '<div>';
            html += ALTUI_PluginDisplays.createOnOffButton( ready, "rachiodev-enabled-" + device.altuiid, _T("Standby,Ready"), "pull-right");
            html += ('<button class="btn-sm {1}" id="rachiodev-stop-{0}">'+_T("Stop Watering")+'</button>').format(device.altuiid, watering=="0"?"btn-default":"btn-danger");
            html += '</div>';
            html += '<script type="text/javascript">';
            html += "$('div#rachiodev-enabled-{0}').on('click', function() { Rachio1_ALTUI._toggleEnabled('{0}','div#rachiodev-enabled-{0}'); } );".format(device.altuiid);
            html += '$("button#rachiodev-stop-{0}").on("click", function() { Rachio1_ALTUI._deviceAction("{0}", "urn:toggledbits-com:serviceId:RachioDevice1", "DeviceStop"); } );'.format(device.altuiid);
            html += '</script>';
            return html;
    }
    
    function _scheduledraw( device ) {
            var html ="";
            var message = MultiBox.getStatus( device, "urn:toggledbits-com:serviceId:RachioSchedule1", "Message");
            html += '<div>' + message + '</div>';
            html += '<div>';
            html += ('<button class="btn-sm btn-default" id="rachiosched-run-{0}">'+_T("Start")+'</button>').format(device.altuiid);
            html += '</div>';
            html += '<script type="text/javascript">';
            html += '$("button#rachiosched-run-{0}").on("click", function() { Rachio1_ALTUI._deviceAction("{0}", "urn:toggledbits-com:serviceId:RachioSchedule1", "RunSchedule"); } );'.format(device.altuiid);
            html += '</script>';
            return html;
    }
    
    function _zonedraw( device ) {
            var html ="";
            var message = MultiBox.getStatus( device, "urn:toggledbits-com:serviceId:RachioZone1", "Message");
            var val = parseInt( MultiBox.getStatus( device, "urn:toggledbits-com:serviceId:RachioZone1", "Remaining") );
            html += '<div>' + message + '</div>';
            html += ("<div id='slider-{0}' class='altui-dimmable-slider' ><div id='chandle' class='ui-slider-handle' style='font-size:0.8em;width:3em;height:1.5em;top:50%;margin-top:-0.8em;text-align:center;line-height:1.5em;'>{1}</div></div>").format(device.altuiid, val);
            html += '<script type="text/javascript">';
            html += ('$("div#slider-{0}.altui-dimmable-slider").slider({min:0,max:180,value:{1},change:Rachio1_ALTUI._sliderChanged,slide:Rachio1_ALTUI._sliderSlide});').format(device.altuiid, val);
            html += '</script>';
            $(".altui-mainpanel").off("slide","#slider-"+device.altuuid).on("slide","#slider-"+device.altuuid,function( event, ui ) {
                $("#slider-val-"+device.altuuid).text( ui.value + "mins" );
            });
            return html;
    }
    
    function _deviceAction( altuiid, sid, action, params ) {
        MultiBox.runActionByAltuiID( altuiid, sid, action, params || {} );
    }
    
    function _toggleEnabled(altuiid, htmlid) {
        ALTUI_PluginDisplays.toggleButton(altuiid, htmlid, 'urn:toggledbits-com:serviceId:ReactorDevice1', 'On', function(id, newval) {
            console.log("_toggleEnabled newval is " + typeof newval + " " + String(newval));
            if ( newval == 0 ) {
                MultiBox.runActionByAltuiID( altuiid, 'urn:toggledbits-com:serviceId:RachioDevice1', 'DeviceOff', {} );
            } else {
                MultiBox.runActionByAltuiID( altuiid, 'urn:toggledbits-com:serviceId:RachioDevice1', 'DeviceOn', {} );
            }
        });
    }
    
    function _sliderChanged( ev, ui ) {
        // console.log("Slider change to " + String(ui.value));
        var altuiid = $(ui.handle).closest(".altui-device").data("altuiid");
        MultiBox.runActionByAltuiID( altuiid, 'urn:toggledbits-com:serviceId:RachioZone1', 'StartZone', { durationMinutes:ui.value } );
    }
    
    function _sliderSlide( ev, ui ) {
        // console.log("Slider moved to " + String(ui.value));
        var altuiid = $(ui.handle).closest(".altui-device").data("altuiid");
        $('div#slider-' + altuiid + '.altui-dimmable-slider div#chandle').text(ui.value);
    }
    
    
    return {
        /* convenience exports */
        _deviceAction: _deviceAction,
        _toggleEnabled: _toggleEnabled,
        _sliderChanged: _sliderChanged,
        _sliderSlide: _sliderSlide,
        /* true exports */
        ServiceDraw: _servicedraw,
        DeviceDraw: _devicedraw,
        ScheduleDraw: _scheduledraw,
        ZoneDraw: _zonedraw,
        getStyle: _getStyle
    };
})( window );

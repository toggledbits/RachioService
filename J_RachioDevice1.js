//# sourceURL=J_RachioDevice1.js
/** 
 * J_RachioDevice1.js
 * Configuration interface for Rachio device object (Iro controller)
 *
 * Copyright 2016,2017 Patrick H. Rigney, All Rights Reserved.
 * This file is part of the Rachio Plugin for Vera. For license information, see LICENSE at https://github.com/toggledbits/rachio/
 * $Id: J_RachioDevice1.js 65 2017-08-16 21:52:39Z patrick $
 */
 
// "use strict"; // fails under UI7, fine on ALTUI

var RachioDevice1 = (function (api) {

    // unique identifier for this plugin...
    var uuid = "ccdca3bc-6fca-11e7-b3ef-74d4351650de";

    var serviceId = "urn:toggledbits-com:serviceId:RachioDevice1";

    var myModule = {};

    function findDeviceByNum( devList, devNum ) {
        var i;
        for (i=0; i<devList.length; i+=1) {
            if (devList[i].id == devNum)
                return devList[i];
        }
        return undefined;
    }

    function clearControls() {
        $('input.iro-zone-check').attr('checked', false);
        $('select.iro-zone-time').val("0").attr('disabled', true).css('display','none');
        $('button#waterstart').attr('disabled', true);
    }

    function configurePlugin() {
    }

    function zonewatering() {
        try {
            var html = "";

            var devices = api.getListOfDevices();
            var deviceDev = findDeviceByNum( devices, api.getCpanelDeviceId() );
            var serviceDev = findDeviceByNum( devices, deviceDev.id_parent );

            /* Find our zones */
            var zones = [];
            for (var i=0; i<devices.length; ++i) {
                var d = devices[i];
                if (d.id_parent !== undefined
                        && d.id_parent == serviceDev.id
                        && d.device_type == "urn:schemas-toggledbits-com:device:RachioZone:1") {
                    var en = api.getDeviceStateVariable(d.id, "urn:toggledbits-com:serviceId:RachioZone1", "Enabled");
                    if (en && en != 0) {
                        var zn = api.getDeviceStateVariable(d.id, "urn:toggledbits-com:serviceId:RachioZone1", "Number");
                        d.zoneNumber = zn;
                        zones.push(d);
                    }
                }
            }
            zones.sort( function (a, b) {
                if (a.zoneNumber == b.zoneNumber) return 0;
                return a.zoneNumber < b.zoneNumber ? -1 : 1;
            });

            html += '<div id="iro-custom" style="padding: 0 0 16px 0; border-bottom: 1px solid #d3d2d2;">';
            html += '<div id="iro-zone-controls" style="width:630px; margin: 0 auto;">';
            zones.forEach( function (zone) {
                // html += '  <form method="get" action="#">';
                html += '    <div class="clearfix">';
                html += '<div class="pull-left" style="width: 335px">';
                html += '      <input type="checkbox" class="customCheckbox iro-zone-check" id="check' + zone.id + '" value="1">';
                html += '<label for="check' + zone.id + '" class="labelForCustomCheckbox">' + zone.name + "</label>";
                html += '</div>';
                html += '<div class="pull-left customSelectBoxContainer" style="width: 60px;">';
                html += '      <select class="device_cpanel_input_select customSelectBox iro-zone-time" id="time' + zone.id + '">';
                for (var i=0; i<10; ++i) html += '<option value="' + i + '">' + i + "</option>";
                for (var i=10; i<=30; i+=5) html += '<option value="' + i + '">' + i + "</option>";
                html += "      </select>";
                html += '</div>';
                html += "    </div>"; /* row */
                // html += "  </form>";
            });

            html += '<button type="button" id="waterstart" class="cpanel_device_control_button">Start Watering</button>';

            html += "</div>"; /* iro-zone-controls */
            html += "</div>"; /* iro-custom */
			
            // Push generated HTML to page
            api.setCpanelContent(html);

            // Set up defaults and (re)actions
            jQuery(".iro-zone-check").click( function () {
                var id = $(this).attr('id').substr(5);
                $("select#time" + id).attr('disabled', !this.checked).css("display",this.checked ? "inline" : "none");
                $("button#waterstart").attr("disabled", $('input.iro-zone-check:checked').length == 0);
            });
            jQuery('.iro-zone-time').attr('disabled', false).css("display","none");
            jQuery('button#waterstart').attr('disabled', true).click( function () {
                var zonedata = [];
                $("input.iro-zone-check:checked").each( function() {
                    var id = $(this).attr('id').substr(5);
                    var durMinutes = $('select#time' + id).val();
                    var zn = api.getDeviceStateVariable(id, "urn:toggledbits-com:serviceId:RachioZone1", "Number");
                    zonedata.push(zn + "=" + durMinutes);
                });

                api.performLuActionOnDevice( api.getCpanelDeviceId(), serviceId, "StartMultiZone",
                    {
                        "actionArguments" : { "zoneData" : zonedata.join(",") },
                        "onSuccess": function () { clearControls(); },
                        "onFailure": function() { }
                    }
                );
            });

        } catch (e) {
            Utils.logError("Error in RachioDevice1.zonewatering(): " + e);
        }
    }

    myModule = {
        uuid: uuid,
        configurePlugin: configurePlugin,
        zonewatering: zonewatering
    };
    return myModule;
})(api);

# Change Log #

## Version 1.5 (develop branch) ##

* Upgrade detection of AltUI so we don't falsely detect when bridged (on "real" device triggers AltUI feature registration).
* Now runs on openLuup.
* Add Enabled variable to stop plugin operation/API polling.
* Force category/subcategory to switch/valve for zones and schedules. Having it set in the device file doesn't seem to be sufficient.
* Implement SwitchPower1 service (rudimentary) for zones and schedules (supports category/sub).

## Version 1.4 (released) ##

* Version 1.4 contains only some tweaks to better fit with Rachio's latest API changes, and improve/restore the consistency of status messages on the service and controller device dashboard cards.

## Version 1.3 (released) ##

* Additional catch-up with Rachio's API changes. There's still much they've left broken, but it's getting better.

## Version 1.2 (released) ##

* Update the API interface to be more friendly with Rachio's newly introduced API quota of 1700 calls per day.
* Rachio also subsequently released an update to their API that introduced several bugs and removed some data previously available, so attempt to deal with all that. Obviously, I can't fix their bugs, but I can try to keep the plugin from dying, and maybe even do something sensible while staying in control.

## Version 1.1 (released) ##

* Minor cleanups and UI bug fixes.

## Version 1.0 (released) ##

* Initial public release.

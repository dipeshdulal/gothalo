import 'dart:js_interop';

/// Defined in web/index.html: stops every MediaStream getUserMedia has handed
/// out. mobile_scanner's web stop() forgets its stream without stopping the
/// tracks, which keeps the camera (and iOS's indicator) on until the page dies.
@JS('__stopCameraStreams')
external void _stopCameraStreams();

void releaseCameraStreams() => _stopCameraStreams();

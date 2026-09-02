import Foundation

/// The one PCM shape RTI speaks end to end: 16 kHz, mono, Int16 little-endian.
/// The mic tap, the system-audio tap, the WAV legs, and the Soniox streaming
/// config all derive from this value; change it here or nowhere.
public enum AudioFormat {
    public static let sampleRateHz = 16_000
}

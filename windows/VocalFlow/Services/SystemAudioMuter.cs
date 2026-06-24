using NAudio.CoreAudioApi;

namespace VocalFlow.Services;

/// <summary>
/// Mutes the default playback device while recording so feedback chimes / system audio aren't
/// picked up by the mic, then restores the prior mute state. Port of the macOS SystemAudioMuter
/// (CoreAudio kAudioDevicePropertyMute -> NAudio AudioEndpointVolume.Mute).
/// </summary>
public sealed class SystemAudioMuter
{
    private bool _previousMuteState;

    public void Mute()
    {
        try
        {
            using var enumerator = new MMDeviceEnumerator();
            using var device = enumerator.GetDefaultAudioEndpoint(DataFlow.Render, Role.Console);
            _previousMuteState = device.AudioEndpointVolume.Mute;
            device.AudioEndpointVolume.Mute = true;
        }
        catch { /* no default output / no access -> no-op */ }
    }

    public void Unmute()
    {
        try
        {
            using var enumerator = new MMDeviceEnumerator();
            using var device = enumerator.GetDefaultAudioEndpoint(DataFlow.Render, Role.Console);
            device.AudioEndpointVolume.Mute = _previousMuteState;
        }
        catch { /* no-op */ }
    }
}

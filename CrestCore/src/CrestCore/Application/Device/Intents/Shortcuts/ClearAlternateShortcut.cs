using CrestCore.Application;
using CrestCore.Domain;

namespace CrestCore.Contracts;

/// Changes the optional alternate while preserving the primary chord.
public sealed record ClearAlternateShortcut(ShortcutCommand Command) : ShortcutIntent {
    #region Actions - Device

    internal override void Apply(Device device, ShortcutTurn turn) =>
        device.ReviseShortcuts(turn, shortcuts => shortcuts.ClearingAlternate(Command));

    #endregion
}

using CrestCore.Application;
using CrestCore.Domain;

namespace CrestCore.Contracts;

/// Changes the optional alternate while preserving the primary chord.
public sealed record AssignAlternateShortcut(ShortcutCommand Command, KeyCombination Keys) : ShortcutIntent {
    #region Actions - Device

    internal override void Apply(Device device, ShortcutTurn turn) =>
        device.ReviseShortcuts(turn, shortcuts => shortcuts.AssigningAlternate(Command, Device.Chord(Keys), turn.Offered, device.Platform));

    #endregion
}

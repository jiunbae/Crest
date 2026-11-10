using CrestCore.Application;
using CrestCore.Domain;

namespace CrestCore.Contracts;

/// Clears the primary chord of `Command`, preserving its optional alternate.
public sealed record UnassignShortcut(ShortcutCommand Command) : ShortcutIntent {
    #region Actions - Device

    internal override void Apply(Device device, ShortcutTurn turn) =>
        device.ReviseShortcuts(turn, shortcuts => shortcuts.Unassigning(Command, device.Platform));

    #endregion
}

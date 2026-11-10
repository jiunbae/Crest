using CrestCore.Contracts;

namespace CrestCore.Domain;

/// The person's shortcut choices on this device: for each command's stored
/// name, the chord they gave it, or null when they left it without one, and
/// who answers its keys while a focused page uses them too. A choice for a
/// command this build does not know is carried through, and one equal to the
/// command's default is never kept.
///
/// `offered` is the ordered set of commands this device shows anywhere; only
/// they can hold or lose a chord. A default that yields to overrides never
/// takes a chord the person gave another offered command; resetting that
/// command restores it. Values are immutable: every change answers a new one.
public sealed class ShortcutOverrides {
    #region Static Variables

    public const int MaximumOverrides = 256;
    public const int MaximumCommandLength = 64;

    public static readonly ShortcutOverrides None = new(new SortedDictionary<string, ShortcutChord?>(StringComparer.Ordinal),
        new SortedDictionary<string, ShortcutPreference>(StringComparer.Ordinal),
        new SortedDictionary<string, ShortcutChord>(StringComparer.Ordinal));

    #endregion

    #region Variables

    private readonly SortedDictionary<string, ShortcutChord?> chords;
    private readonly SortedDictionary<string, ShortcutPreference> preferences;
    private readonly SortedDictionary<string, ShortcutChord> alternates;

    /// Every chord choice, by command name in ordinal order.
    public IEnumerable<KeyValuePair<string, ShortcutChord?>> Chords => chords;

    /// Every preference choice, by command name in ordinal order.
    public IEnumerable<KeyValuePair<string, ShortcutPreference>> Preferences => preferences;

    /// Every optional alternate, by command name in ordinal order.
    public IEnumerable<KeyValuePair<string, ShortcutChord>> Alternates => alternates;

    /// Whether the person changed any shortcut, including one this device does not offer.
    public bool IsCustomized => chords.Count > 0 || preferences.Count > 0 || alternates.Count > 0;

    #endregion

    #region Constructors

    private ShortcutOverrides(SortedDictionary<string, ShortcutChord?> chords, SortedDictionary<string, ShortcutPreference> preferences,
        SortedDictionary<string, ShortcutChord> alternates) {
        this.chords = chords;
        this.preferences = preferences;
        this.alternates = alternates;
    }

    /// The choices `stored` and `preferred` name, the first for each command
    /// name, leaving out names no command could have and anything past the
    /// limit.
    public static ShortcutOverrides Restore(IEnumerable<KeyValuePair<string, ShortcutChord?>> stored,
        IEnumerable<KeyValuePair<string, ShortcutPreference>>? preferred = null,
        IEnumerable<KeyValuePair<string, ShortcutChord>>? alternate = null) {
        ArgumentNullException.ThrowIfNull(stored);
        return new(Kept(stored), Kept(preferred ?? []), Kept(alternate ?? []));
    }

    private static SortedDictionary<string, T> Kept<T>(IEnumerable<KeyValuePair<string, T>> stored) {
        var kept = new SortedDictionary<string, T>(StringComparer.Ordinal);
        foreach (var (command, choice) in stored) {
            if (kept.Count >= MaximumOverrides) break;
            if (command.Length is 0 or > MaximumCommandLength) continue;
            kept.TryAdd(command, choice);
        }
        return kept;
    }

    #endregion

    #region Actions - Resolution

    /// Each offered command's chord and preference now, in `offered` order.
    public IReadOnlyList<ShortcutBinding> Bindings(IReadOnlyList<ShortcutCommand> offered, DevicePlatform platform) =>
        [.. offered.Select(command => Binding(command, Effective(command, offered, platform)))];

    /// A command bound to text editing keys leaves them to the page and the
    /// field, whatever it prefers, so it has no preference to choose.
    private ShortcutBinding Binding(ShortcutCommand command, ShortcutChord? chord) {
        var primary = Policy(command, chord);
        var alternate = alternates.GetValueOrDefault(command.Name);
        return new(command, chord?.Keys, chords.ContainsKey(command.Name) || preferences.ContainsKey(command.Name)
            || alternates.ContainsKey(command.Name), primary.Preference, primary.ChoosesPreference, primary.YieldsToTextEditing,
            alternate is not null && alternate != chord ? Policy(command, alternate) : null);
    }

    private ShortcutChordBinding Policy(ShortcutCommand command, ShortcutChord? chord) {
        bool editsText = chord?.EditsText == true;
        bool chooses = !command.IsReservedFromPages && !editsText;
        var preference = editsText ? ShortcutPreference.PreferWebsite
            : chooses ? preferences.GetValueOrDefault(command.Name) ?? command.DefaultPreference : command.DefaultPreference;
        return new(chord?.Keys, preference, chooses, editsText);
    }

    /// The chord `command` answers to now.
    public ShortcutChord? Effective(ShortcutCommand command, IReadOnlyList<ShortcutCommand> offered, DevicePlatform platform) {
        ArgumentNullException.ThrowIfNull(command);
        ArgumentNullException.ThrowIfNull(offered);
        if (chords.TryGetValue(command.Name, out var custom)) return custom;
        if (command.DefaultShortcut(platform) is not { } fallback) return null;
        var chord = ShortcutChord.Of(fallback.Keys);
        if (fallback.YieldsToOverrides && offered.Any(other => (chords.TryGetValue(other.Name, out var taken) && taken == chord)
            || (other != command && alternates.GetValueOrDefault(other.Name) == chord))) return null;
        return chord;
    }

    /// The other offered commands that answer to `chord` now.
    public IReadOnlyList<ShortcutCommand> Holders(ShortcutChord chord, ShortcutCommand command, IReadOnlyList<ShortcutCommand> offered,
        DevicePlatform platform) =>
        [.. offered.Where(other => other != command && (Effective(other, offered, platform) == chord
            || alternates.GetValueOrDefault(other.Name) == chord))];

    #endregion

    #region Actions - Changes

    /// `command` answering to `chord`. Throws `Rejected` with `ShortcutInUse`
    /// naming every other offered command that answers to it.
    public ShortcutOverrides Assigning(ShortcutCommand command, ShortcutChord chord, IReadOnlyList<ShortcutCommand> offered,
        DevicePlatform platform) {
        var holders = Holders(chord, command, offered, platform);
        if (holders.Count > 0) throw new Rejected(new ShortcutInUse(holders));
        return Setting(command, chord, platform);
    }

    /// `command` answering to `chord`, which every other offered command that
    /// answered to it gives up.
    public ShortcutOverrides Reassigning(ShortcutCommand command, ShortcutChord chord, IReadOnlyList<ShortcutCommand> offered,
        DevicePlatform platform) {
        return RemovingHolders(chord, command, offered, platform).Setting(command, chord, platform);
    }

    private ShortcutOverrides RemovingHolders(ShortcutChord chord, ShortcutCommand command, IReadOnlyList<ShortcutCommand> offered,
        DevicePlatform platform) {
        var revised = this;
        foreach (var holder in Holders(chord, command, offered, platform)) {
            if (revised.Effective(holder, offered, platform) == chord) revised = revised.Setting(holder, null, platform);
            if (revised.alternates.GetValueOrDefault(holder.Name) == chord) revised = revised.SettingAlternate(holder, null);
        }
        return revised;
    }

    /// `command` answering to no primary chord, retaining its alternate.
    public ShortcutOverrides Unassigning(ShortcutCommand command, DevicePlatform platform) => Setting(command, null, platform);

    /// Binds a second chord without changing the primary or its preference.
    public ShortcutOverrides AssigningAlternate(ShortcutCommand command, ShortcutChord chord, IReadOnlyList<ShortcutCommand> offered,
        DevicePlatform platform) {
        var holders = Holders(chord, command, offered, platform);
        if (holders.Count > 0) throw new Rejected(new ShortcutInUse(holders));
        return SettingAlternate(command, Effective(command, offered, platform) == chord ? null : chord);
    }

    /// Takes only the colliding chord from each holder, keeping its other chord.
    public ShortcutOverrides ReassigningAlternate(ShortcutCommand command, ShortcutChord chord, IReadOnlyList<ShortcutCommand> offered,
        DevicePlatform platform) => RemovingHolders(chord, command, offered, platform)
            .SettingAlternate(command, Effective(command, offered, platform) == chord ? null : chord);

    public ShortcutOverrides ClearingAlternate(ShortcutCommand command) => SettingAlternate(command, null);

    /// The choices with each chord that holds Shift and the symbol one of
    /// `digits` types under it named by that digit instead, as the catalog
    /// names ⇧⌘2. A chord whose digit another offered command would then
    /// answer to keeps its symbol, so nothing loses its keys.
    public ShortcutOverrides ReadingShiftedDigits(IReadOnlyList<ShiftedDigit> digits, IReadOnlyList<ShortcutCommand> offered,
        DevicePlatform platform) {
        ArgumentNullException.ThrowIfNull(digits);
        var revised = this;
        foreach (var (name, chord) in chords) {
            if (chord is not { IsSpecial: false } held || (held.Modifiers & ShortcutChord.Shift) == 0
                || digits.FirstOrDefault(digit => digit.Symbol == held.Key) is not { } shifted) continue;
            var renamed = ShortcutChord.Character(shifted.Digit, held.Modifiers);
            if (ShortcutCommand.Named(name) is not { } command) {
                revised = revised.Replacing(name, renamed);
                continue;
            }
            var candidate = revised.Setting(command, renamed, platform);
            if (candidate.Holders(renamed, command, offered, platform).Count == 0) revised = candidate;
        }
        return revised;
    }

    /// `command` back on its default.
    public ShortcutOverrides Resetting(ShortcutCommand command) {
        ArgumentNullException.ThrowIfNull(command);
        if (!chords.ContainsKey(command.Name) && !preferences.ContainsKey(command.Name) && !alternates.ContainsKey(command.Name)) return this;
        var revised = new SortedDictionary<string, ShortcutChord?>(chords, StringComparer.Ordinal);
        var preferred = new SortedDictionary<string, ShortcutPreference>(preferences, StringComparer.Ordinal);
        revised.Remove(command.Name);
        preferred.Remove(command.Name);
        var alternate = new SortedDictionary<string, ShortcutChord>(alternates, StringComparer.Ordinal);
        alternate.Remove(command.Name);
        return new(revised, preferred, alternate);
    }

    /// `preference` answering `command`'s keys while a focused page uses them
    /// too; one equal to its default is no choice at all. A command reserved
    /// from pages keeps its own.
    public ShortcutOverrides Preferring(ShortcutCommand command, ShortcutPreference preference) {
        ArgumentNullException.ThrowIfNull(command);
        ArgumentNullException.ThrowIfNull(preference);
        if (command.IsReservedFromPages) return this;
        var preferred = new SortedDictionary<string, ShortcutPreference>(preferences, StringComparer.Ordinal);
        if (preference == command.DefaultPreference) preferred.Remove(command.Name);
        else preferred[command.Name] = preference;
        return new(chords, preferred, alternates);
    }

    /// The choices with `chord` for the command stored as `name`, which this
    /// build does not know.
    private ShortcutOverrides Replacing(string name, ShortcutChord chord) =>
        new(new SortedDictionary<string, ShortcutChord?>(chords, StringComparer.Ordinal) { [name] = chord }, preferences, alternates);

    /// The choices with `chord` for `command`; one equal to its default is
    /// no choice at all.
    private ShortcutOverrides Setting(ShortcutCommand command, ShortcutChord? chord, DevicePlatform platform) {
        ArgumentNullException.ThrowIfNull(command);
        ArgumentNullException.ThrowIfNull(platform);
        var fallback = command.DefaultShortcut(platform) is { } keys ? ShortcutChord.Of(keys.Keys) : null;
        var revised = new SortedDictionary<string, ShortcutChord?>(chords, StringComparer.Ordinal);
        if (chord == fallback) revised.Remove(command.Name);
        else revised[command.Name] = chord;
        var alternate = new SortedDictionary<string, ShortcutChord>(alternates, StringComparer.Ordinal);
        if (chord is not null && alternate.GetValueOrDefault(command.Name) == chord) alternate.Remove(command.Name);
        return new(revised, preferences, alternate);
    }

    private ShortcutOverrides SettingAlternate(ShortcutCommand command, ShortcutChord? chord) {
        ArgumentNullException.ThrowIfNull(command);
        var revised = new SortedDictionary<string, ShortcutChord>(alternates, StringComparer.Ordinal);
        if (chord is null) revised.Remove(command.Name);
        else revised[command.Name] = chord;
        return new(chords, preferences, revised);
    }

    #endregion

    #region Actions - Equality

    /// Whether `other` holds the same choices.
    public bool SameAs(ShortcutOverrides? other) =>
        other is not null && chords.Count == other.chords.Count && preferences.Count == other.preferences.Count
        && alternates.Count == other.alternates.Count
        && alternates.All(entry => other.alternates.TryGetValue(entry.Key, out var chord) && chord == entry.Value)
        && chords.All(entry => other.chords.TryGetValue(entry.Key, out var chord) && chord == entry.Value)
        && preferences.All(entry => other.preferences.TryGetValue(entry.Key, out var preference) && preference == entry.Value);

    #endregion
}

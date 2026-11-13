using System.ComponentModel;
using System.Globalization;
using System.Windows.Data;
using System.Windows.Markup;
using Shanchuan.Core;
using Binding = System.Windows.Data.Binding;

namespace Shanchuan.Windows;

/// <summary>One observable revision refreshes existing bindings, not view instances.</summary>
public sealed class LocalizationSource : INotifyPropertyChanged
{
    public static LocalizationSource Instance { get; } = new();
    public int Revision { get; private set; }
    public event PropertyChangedEventHandler? PropertyChanged;
    private LocalizationSource()
    {
        L.LanguageChanged += () =>
        {
            void Notify() { Revision++; PropertyChanged?.Invoke(this, new PropertyChangedEventArgs(nameof(Revision))); }
            var dispatcher = System.Windows.Application.Current?.Dispatcher;
            if (dispatcher is not null && !dispatcher.CheckAccess()) dispatcher.Invoke(Notify);
            else Notify();
        };
    }
}

[MarkupExtensionReturnType(typeof(string))]
public sealed class TrExtension : MarkupExtension
{
    public string Key { get; set; } = "";
    public override object ProvideValue(IServiceProvider serviceProvider) => new Binding(nameof(LocalizationSource.Revision))
    {
        Source = LocalizationSource.Instance,
        Mode = BindingMode.OneWay,
        Converter = new TranslationConverter(Key)
    }.ProvideValue(serviceProvider);
}

public sealed class TranslationConverter(string key) : IValueConverter
{
    public object Convert(object value, Type targetType, object parameter, CultureInfo culture) => L.T(key);
    public object ConvertBack(object value, Type targetType, object parameter, CultureInfo culture) => throw new NotSupportedException();
}

public sealed class LocalizedValueConverter : IValueConverter, IMultiValueConverter
{
    public object Convert(object value, Type targetType, object parameter, CultureInfo culture) => value switch
    {
        TransferLogLevel.Info => L.T("信息"),
        TransferLogLevel.Success => L.T("成功"),
        TransferLogLevel.Warning => L.T("警告"),
        TransferLogLevel.Error => L.T("错误"),
        TransferLogLevel.Cancelled => L.T("已取消"),
        _ => value
    };
    public object Convert(object[] values, Type targetType, object parameter, CultureInfo culture) =>
        Convert(values[0], targetType, parameter, culture);
    public object ConvertBack(object value, Type targetType, object parameter, CultureInfo culture) => throw new NotSupportedException();
    public object[] ConvertBack(object value, Type[] targetTypes, object parameter, CultureInfo culture) => throw new NotSupportedException();
}

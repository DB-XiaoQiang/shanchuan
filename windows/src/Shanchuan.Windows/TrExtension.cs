using System.Globalization;
using System.Windows.Data;
using System.Windows.Markup;
using Shanchuan.Core;

namespace Shanchuan.Windows;

/// <summary>Central resource lookup for XAML. Language changes take effect after restart.</summary>
[MarkupExtensionReturnType(typeof(string))]
public sealed class TrExtension : MarkupExtension
{
    public string Key { get; set; } = "";
    public override object ProvideValue(IServiceProvider serviceProvider) => L.T(Key);
}

public sealed class LocalizedValueConverter : IValueConverter
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
    public object ConvertBack(object value, Type targetType, object parameter, CultureInfo culture) =>
        throw new NotSupportedException();
}

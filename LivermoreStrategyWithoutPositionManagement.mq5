//+------------------------------------------------------------------+
//|                                          LivermoreStrategyEA.mq5 |
//|                        Copyright 2024, MetaQuotes Software Corp. |
//|                                             https://www.mql5.com |
//+------------------------------------------------------------------+
#property copyright "Copyright 2024, MetaQuotes Software Corp."
#property link      "https://www.mql5.com"
#property version   "1.00"

#include <Trade\Trade.mqh>
#include <Trade\PositionInfo.mqh>

//--- 输入参数
input group "=== 策略参数 ==="
input int    ATR_Period = 10;           // ATR 周期
input double SuperTrend_Factor = 3.0;   // SuperTrend 因子
input int    MACD_Fast = 12;            // MACD 快线
input int    MACD_Slow = 26;            // MACD 慢线
input int    MACD_Signal = 9;           // MACD 信号线

input group "=== 交易参数 ==="
input double LotSize = 0.1;             // 手数
input int    MagicNumber = 123456;      // 魔术数字
input int    Slippage = 3;              // 滑点
input bool   UseStopLoss = true;        // 使用止损
input bool   UseTakeProfit = true;      // 使用止盈
input double StopLoss_Points = 100;     // 止损点数
input double TakeProfit_Points = 200;   // 止盈点数

input group "=== 风险管理 ==="
input double MaxRiskPercent = 2.0;      // 最大风险百分比

input group "=== 时间过滤 ==="
input bool   UseTimeFilter = false;     // 使用时间过滤
input int    StartHour = 8;             // 开始小时
input int    EndHour = 18;              // 结束小时

//--- 全局变量
CTrade trade;
CPositionInfo positionInfo;
double lastBuyPrice = 0;
datetime lastBuyTime = 0;
bool hasPosition = false;
int totalTrades = 0;
int winningTrades = 0;
double totalProfit = 0;

//--- 指标句柄和缓冲区
int atrHandle;
int macdHandle;
int ema3Handle, ema5Handle, ema8Handle, ema10Handle, ema12Handle, ema15Handle;
int ema30Handle, ema35Handle, ema40Handle, ema45Handle, ema50Handle, ema60Handle;

double supertrendBuffer[];
double gmmaShortBuffer[];
double gmmaLongBuffer[];
double macdLineBuffer[];
double signalLineBuffer[];

//+------------------------------------------------------------------+
//| Expert initialization function                                   |
//+------------------------------------------------------------------+
int OnInit()
{
    //--- 设置交易对象
    trade.SetExpertMagicNumber(MagicNumber);
    trade.SetDeviationInPoints(Slippage);
    trade.SetTypeFilling(ORDER_FILLING_FOK);
    
    //--- 获取指标句柄
    atrHandle = iATR(_Symbol, _Period, ATR_Period);
    macdHandle = iMACD(_Symbol, _Period, MACD_Fast, MACD_Slow, MACD_Signal, PRICE_CLOSE);
    
    //--- GMMA指标句柄
    ema3Handle = iMA(_Symbol, _Period, 3, 0, MODE_EMA, PRICE_CLOSE);
    ema5Handle = iMA(_Symbol, _Period, 5, 0, MODE_EMA, PRICE_CLOSE);
    ema8Handle = iMA(_Symbol, _Period, 8, 0, MODE_EMA, PRICE_CLOSE);
    ema10Handle = iMA(_Symbol, _Period, 10, 0, MODE_EMA, PRICE_CLOSE);
    ema12Handle = iMA(_Symbol, _Period, 12, 0, MODE_EMA, PRICE_CLOSE);
    ema15Handle = iMA(_Symbol, _Period, 15, 0, MODE_EMA, PRICE_CLOSE);
    
    ema30Handle = iMA(_Symbol, _Period, 30, 0, MODE_EMA, PRICE_CLOSE);
    ema35Handle = iMA(_Symbol, _Period, 35, 0, MODE_EMA, PRICE_CLOSE);
    ema40Handle = iMA(_Symbol, _Period, 40, 0, MODE_EMA, PRICE_CLOSE);
    ema45Handle = iMA(_Symbol, _Period, 45, 0, MODE_EMA, PRICE_CLOSE);
    ema50Handle = iMA(_Symbol, _Period, 50, 0, MODE_EMA, PRICE_CLOSE);
    ema60Handle = iMA(_Symbol, _Period, 60, 0, MODE_EMA, PRICE_CLOSE);
    
    //--- 设置数组为时间序列
    ArraySetAsSeries(supertrendBuffer, true);
    ArraySetAsSeries(gmmaShortBuffer, true);
    ArraySetAsSeries(gmmaLongBuffer, true);
    ArraySetAsSeries(macdLineBuffer, true);
    ArraySetAsSeries(signalLineBuffer, true);
    
    //--- 初始化指标缓冲区
    if(!InitIndicatorBuffers())
    {
        Print("错误：初始化指标缓冲区失败");
        return(INIT_FAILED);
    }
    
    //--- 检查交易权限
    if(!TerminalInfoInteger(TERMINAL_TRADE_ALLOWED))
    {
        Print("错误：终端不允许交易");
        return(INIT_FAILED);
    }
    
    if(!MQLInfoInteger(MQL_TRADE_ALLOWED))
    {
        Print("错误：EA不允许交易");
        return(INIT_FAILED);
    }
    
    Print("Livermore Strategy EA 初始化成功");
    return(INIT_SUCCEEDED);
}

//+------------------------------------------------------------------+
//| 初始化指标缓冲区                                                |
//+------------------------------------------------------------------+
bool InitIndicatorBuffers()
{
    //--- 计算初始SuperTrend值
    CalculateSuperTrendArray();
    
    //--- 计算初始GMMA值
    CalculateGMMAArrays();
    
    //--- 获取初始MACD值
    double macdTmp[2], signalTmp[2];
    if(CopyBuffer(macdHandle, 0, 0, 2, macdTmp) < 2 || 
       CopyBuffer(macdHandle, 1, 0, 2, signalTmp) < 2)
    {
        return false;
    }
    
    macdLineBuffer[0] = macdTmp[0];
    macdLineBuffer[1] = macdTmp[1];
    signalLineBuffer[0] = signalTmp[0];
    signalLineBuffer[1] = signalTmp[1];
    
    return true;
}

//+------------------------------------------------------------------+
//| Expert deinitialization function                                 |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
    //--- 释放指标句柄
    ReleaseHandle(atrHandle);
    ReleaseHandle(macdHandle);
    ReleaseHandle(ema3Handle);
    ReleaseHandle(ema5Handle);
    ReleaseHandle(ema8Handle);
    ReleaseHandle(ema10Handle);
    ReleaseHandle(ema12Handle);
    ReleaseHandle(ema15Handle);
    ReleaseHandle(ema30Handle);
    ReleaseHandle(ema35Handle);
    ReleaseHandle(ema40Handle);
    ReleaseHandle(ema45Handle);
    ReleaseHandle(ema50Handle);
    ReleaseHandle(ema60Handle);
    
    //--- 打印统计信息
    Print("=== 交易统计 ===");
    Print("总交易次数: ", totalTrades);
    Print("盈利交易: ", winningTrades);
    Print("胜率: ", totalTrades > 0 ? DoubleToString((double)winningTrades/totalTrades*100, 2) + "%" : "0%");
    Print("总盈亏: ", DoubleToString(totalProfit, 2));
}

//+------------------------------------------------------------------+
//| 释放指标句柄                                                    |
//+------------------------------------------------------------------+
void ReleaseHandle(int &handle)
{
    if(handle != INVALID_HANDLE)
    {
        IndicatorRelease(handle);
        handle = INVALID_HANDLE;
    }
}

//+------------------------------------------------------------------+
//| Expert tick function                                             |
//+------------------------------------------------------------------+
void OnTick()
{
    //--- 检查新柱
    static datetime lastBarTime = 0;
    datetime currentBarTime = iTime(_Symbol, _Period, 0);
    
    if(currentBarTime != lastBarTime)
    {
        // 新柱形成，更新所有指标
        lastBarTime = currentBarTime;
        UpdateIndicators();
    }
    
    //--- 时间过滤
    if(UseTimeFilter && !IsTimeToTrade())
        return;
    
    //--- 检查是否有持仓
    hasPosition = CheckOurPosition();
    
    //--- 如果有持仓，检查卖出信号
    if(hasPosition)
    {
        if(CheckSellSignal())
        {
            ClosePosition();
        }
    }
    //--- 如果没有持仓，检查买入信号
    else if(CheckBuySignal())
    {
        OpenBuyPosition();
    }
}

//+------------------------------------------------------------------+
//| 更新所有指标数据                                                |
//+------------------------------------------------------------------+
void UpdateIndicators()
{
    CalculateSuperTrendArray();
    CalculateGMMAArrays();
    
    // 更新MACD
    double macdTmp[2], signalTmp[2];
    if(CopyBuffer(macdHandle, 0, 0, 2, macdTmp) == 2 && 
       CopyBuffer(macdHandle, 1, 0, 2, signalTmp) == 2)
    {
        macdLineBuffer[0] = macdTmp[0];
        macdLineBuffer[1] = macdTmp[1];
        signalLineBuffer[0] = signalTmp[0];
        signalLineBuffer[1] = signalTmp[1];
    }
}

//+------------------------------------------------------------------+
//| 计算SuperTrend数组                                              |
//+------------------------------------------------------------------+
void CalculateSuperTrendArray()
{
    int rates_total = Bars(_Symbol, _Period);
    if(rates_total <= ATR_Period) return;
    
    // 调整缓冲区大小
    if(ArraySize(supertrendBuffer) < rates_total)
        ArrayResize(supertrendBuffer, rates_total);
    
    double atrValues[], highValues[], lowValues[];
    ArraySetAsSeries(atrValues, true);
    ArraySetAsSeries(highValues, true);
    ArraySetAsSeries(lowValues, true);
    
    // 复制数据
    if(CopyBuffer(atrHandle, 0, 0, rates_total, atrValues) < rates_total ||
       CopyHigh(_Symbol, _Period, 0, rates_total, highValues) < rates_total ||
       CopyLow(_Symbol, _Period, 0, rates_total, lowValues) < rates_total)
    {
        return;
    }
    
    // 计算SuperTrend
    for(int i = rates_total - 1; i >= 0; i--)
    {
        double hl2 = (highValues[i] + lowValues[i]) / 2.0;
        double upperBand = hl2 + (SuperTrend_Factor * atrValues[i]);
        double lowerBand = hl2 - (SuperTrend_Factor * atrValues[i]);
        
        if(i == rates_total - 1)
        {
            supertrendBuffer[i] = lowerBand;
            continue;
        }
        
        if(Close[i] <= supertrendBuffer[i + 1])
            supertrendBuffer[i] = MathMin(upperBand, supertrendBuffer[i + 1]);
        else
            supertrendBuffer[i] = MathMax(lowerBand, supertrendBuffer[i + 1]);
    }
}

//+------------------------------------------------------------------+
//| 计算GMMA数组                                                    |
//+------------------------------------------------------------------+
void CalculateGMMAArrays()
{
    int rates_total = Bars(_Symbol, _Period);
    if(rates_total < 60) return;
    
    // 调整缓冲区大小
    if(ArraySize(gmmaShortBuffer) < rates_total)
    {
        ArrayResize(gmmaShortBuffer, rates_total);
        ArrayResize(gmmaLongBuffer, rates_total);
    }
    
    double ema3[], ema5[], ema8[], ema10[], ema12[], ema15[];
    double ema30[], ema35[], ema40[], ema45[], ema50[], ema60[];
    
    ArraySetAsSeries(ema3, true);
    ArraySetAsSeries(ema5, true);
    ArraySetAsSeries(ema8, true);
    ArraySetAsSeries(ema10, true);
    ArraySetAsSeries(ema12, true);
    ArraySetAsSeries(ema15, true);
    ArraySetAsSeries(ema30, true);
    ArraySetAsSeries(ema35, true);
    ArraySetAsSeries(ema40, true);
    ArraySetAsSeries(ema45, true);
    ArraySetAsSeries(ema50, true);
    ArraySetAsSeries(ema60, true);
    
    // 复制EMA数据
    if(CopyBuffer(ema3Handle, 0, 0, rates_total, ema3) < rates_total ||
       CopyBuffer(ema5Handle, 0, 0, rates_total, ema5) < rates_total ||
       CopyBuffer(ema8Handle, 0, 0, rates_total, ema8) < rates_total ||
       CopyBuffer(ema10Handle, 0, 0, rates_total, ema10) < rates_total ||
       CopyBuffer(ema12Handle, 0, 0, rates_total, ema12) < rates_total ||
       CopyBuffer(ema15Handle, 0, 0, rates_total, ema15) < rates_total ||
       CopyBuffer(ema30Handle, 0, 0, rates_total, ema30) < rates_total ||
       CopyBuffer(ema35Handle, 0, 0, rates_total, ema35) < rates_total ||
       CopyBuffer(ema40Handle, 0, 0, rates_total, ema40) < rates_total ||
       CopyBuffer(ema45Handle, 0, 0, rates_total, ema45) < rates_total ||
       CopyBuffer(ema50Handle, 0, 0, rates_total, ema50) < rates_total ||
       CopyBuffer(ema60Handle, 0, 0, rates_total, ema60) < rates_total)
    {
        return;
    }
    
    // 计算GMMA
    for(int i = 0; i < rates_total; i++)
    {
        gmmaShortBuffer[i] = (ema3[i] + ema5[i] + ema8[i] + ema10[i] + ema12[i] + ema15[i]) / 6.0;
        gmmaLongBuffer[i] = (ema30[i] + ema35[i] + ema40[i] + ema45[i] + ema50[i] + ema60[i]) / 6.0;
    }
}

//+------------------------------------------------------------------+
//| 检查是否有本EA的持仓                                            |
//+------------------------------------------------------------------+
bool CheckOurPosition()
{
    for(int i = PositionsTotal() - 1; i >= 0; i--)
    {
        if(positionInfo.SelectByIndex(i))
        {
            if(positionInfo.Symbol() == _Symbol && 
               positionInfo.Magic() == MagicNumber)
            {
                return true;
            }
        }
    }
    return false;
}

//+------------------------------------------------------------------+
//| 检查买入信号                                                    |
//+------------------------------------------------------------------+
bool CheckBuySignal()
{
    //--- GMMA上穿条件
    bool gmmaCrossUp = (gmmaShortBuffer[0] > gmmaLongBuffer[0]) && (gmmaShortBuffer[1] <= gmmaLongBuffer[1]);
    bool gmmaPrevCondition = (gmmaShortBuffer[1] <= gmmaLongBuffer[1]) || (gmmaShortBuffer[2] <= gmmaLongBuffer[2]);
    bool gmmaSignal = gmmaCrossUp && gmmaPrevCondition;
    
    //--- SuperTrend条件
    bool priceAboveSupertrend = Close[0] > supertrendBuffer[0];
    bool supertrendRising = supertrendBuffer[0] > supertrendBuffer[1];
    bool supertrendSignal = priceAboveSupertrend && supertrendRising;
    
    //--- 综合买入信号
    bool buySignal = gmmaSignal && supertrendSignal;
    
    if(buySignal)
    {
        Print("买入信号触发 - GMMA上穿: ", gmmaSignal, ", SuperTrend上升: ", supertrendSignal);
    }
    
    return buySignal;
}

//+------------------------------------------------------------------+
//| 检查卖出信号                                                    |
//+------------------------------------------------------------------+
bool CheckSellSignal()
{
    //--- GMMA下穿条件
    bool gmmaCrossDown = (gmmaShortBuffer[0] < gmmaLongBuffer[0]) && (gmmaShortBuffer[1] >= gmmaLongBuffer[1]);
    bool gmmaPrevConditionSell = gmmaShortBuffer[1] >= gmmaLongBuffer[1];
    bool gmmaSellSignal = gmmaCrossDown && gmmaPrevConditionSell;
    
    //--- SuperTrend条件
    bool priceBelowSupertrend = Close[0] < supertrendBuffer[0];
    bool supertrendFalling = supertrendBuffer[0] < supertrendBuffer[1];
    bool supertrendSellSignal = priceBelowSupertrend && supertrendFalling;
    
    //--- 综合卖出信号
    bool sellSignal = gmmaSellSignal && supertrendSellSignal;
    
    if(sellSignal)
    {
        Print("卖出信号触发 - GMMA下穿: ", gmmaSellSignal, ", SuperTrend下降: ", supertrendSellSignal);
    }
    
    return sellSignal;
}

//+------------------------------------------------------------------+
//| 开多仓                                                          |
//+------------------------------------------------------------------+
void OpenBuyPosition()
{
    double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
    double lot = CalculateLotSize();
    
    double sl = 0, tp = 0;
    
    if(UseStopLoss)
        sl = ask - StopLoss_Points * _Point;
    
    if(UseTakeProfit)
        tp = ask + TakeProfit_Points * _Point;
    
    if(trade.Buy(lot, _Symbol, ask, sl, tp, "Livermore Strategy Buy"))
    {
        lastBuyPrice = ask;
        lastBuyTime = TimeCurrent();
        hasPosition = true;
        totalTrades++;
        
        Print("开多仓成功 - 价格: ", ask, ", 手数: ", lot, ", 止损: ", sl, ", 止盈: ", tp);
    }
    else
    {
        uint error = GetLastError();
        Print("开多仓失败 - 错误代码: ", error, ", 描述: ", ErrorDescription(error));
    }
}

//+------------------------------------------------------------------+
//| 平仓                                                            |
//+------------------------------------------------------------------+
void ClosePosition()
{
    if(trade.PositionClose(_Symbol))
    {
        double profit = PositionGetDouble(POSITION_PROFIT);
        totalProfit += profit;
        
        if(profit > 0)
            winningTrades++;
        
        hasPosition = false;
        
        Print("平仓成功 - 盈亏: ", profit, ", 累计盈亏: ", totalProfit);
    }
    else
    {
        uint error = GetLastError();
        Print("平仓失败 - 错误代码: ", error, ", 描述: ", ErrorDescription(error));
    }
}

//+------------------------------------------------------------------+
//| 计算手数                                                        |
//+------------------------------------------------------------------+
double CalculateLotSize()
{
    if(MaxRiskPercent <= 0)
        return LotSize;
    
    double accountBalance = AccountInfoDouble(ACCOUNT_BALANCE);
    double riskAmount = accountBalance * MaxRiskPercent / 100.0;
    double tickValue = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
    double stopLossPoints = StopLoss_Points;
    
    if(stopLossPoints <= 0)
        return LotSize;
    
    double calculatedLot = riskAmount / (stopLossPoints * _Point * tickValue);
    
    //--- 标准化手数
    double minLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
    double maxLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
    double lotStep = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
    
    calculatedLot = MathMax(calculatedLot, minLot);
    calculatedLot = MathMin(calculatedLot, maxLot);
    calculatedLot = NormalizeDouble(calculatedLot / lotStep, 0) * lotStep;
    
    return calculatedLot;
}

//+------------------------------------------------------------------+
//| 时间过滤                                                        |
//+------------------------------------------------------------------+
bool IsTimeToTrade()
{
    MqlDateTime dt;
    TimeToStruct(TimeCurrent(), dt);
    
    if(StartHour <= EndHour)
    {
        return (dt.hour >= StartHour && dt.hour < EndHour);
    }
    else
    {
        return (dt.hour >= StartHour || dt.hour < EndHour);
    }
}

//+------------------------------------------------------------------+
//| 错误描述                                                        |
//+------------------------------------------------------------------+
string ErrorDescription(int error_code)
{
    switch(error_code)
    {
        case 0:     return "没有错误";
        case 1:     return "没有错误，但结果未知";
        case 2:     return "通用错误";
        case 3:     return "无效参数";
        case 4:     return "服务器忙";
        case 5:     return "旧版本";
        case 6:     return "没有连接";
        case 7:     return "权限不足";
        case 8:     return "太频繁请求";
        case 9:     return "违规操作";
        case 64:    return "账户被禁用";
        case 65:    return "无效账户";
        case 128:   return "交易超时";
        case 129:   return "无效价格";
        case 130:   return "无效止损";
        case 131:   return "无效交易量";
        case 132:   return "市场关闭";
        case 133:   return "交易被禁用";
        case 134:   return "资金不足";
        case 135:   return "价格变化";
        case 136:   return "没有报价";
        case 137:   return "经纪人忙";
        case 138:   return "重新报价";
        case 139:   return "订单被锁定";
        case 140:   return "只允许买";
        case 141:   return "尝试次数超过";
        case 145:   return "修改被拒绝，因为订单太接近市场";
        case 146:   return "交易环境忙";
        case 147:   return "止损/take profit 被经纪人禁止";
        case 148:   return "订单数量过多";
        case 149:   return "对冲被禁止";
        case 150:   return "禁止通过FIFO规则平仓";
        default:    return "未知错误";
    }
}
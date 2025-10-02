//+------------------------------------------------------------------+
//|                                          LivermoreStrategyEA.mq5 |
//|                        Copyright 2024, MetaQuotes Software Corp. |
//|                                             https://www.mql5.com |
//+------------------------------------------------------------------+
#property copyright "Copyright 2024, MetaQuotes Software Corp."
#property link      "https://www.mql5.com"
#property version   "1.01"

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

input group "=== 信号过滤 ==="
input int    MinBarsBetweenSignals = 3; // 信号间隔最小K线数

//--- 常量定义
#define INDICATOR_BUFFER_SIZE 100
#define EMA_COUNT 12

//--- 全局变量
CTrade trade;
CPositionInfo positionInfo;
double lastBuyPrice = 0;
datetime lastBuyTime = 0;
datetime lastSignalTime = 0;
bool hasPosition = false;
int totalTrades = 0;
int winningTrades = 0;
double totalProfit = 0;

//--- 指标句柄
int atrHandle;
int macdHandle;
int emaHandles[EMA_COUNT];

//--- 预分配缓冲区
double supertrendBuffer[INDICATOR_BUFFER_SIZE];
double gmmaShortBuffer[INDICATOR_BUFFER_SIZE];
double gmmaLongBuffer[INDICATOR_BUFFER_SIZE];
double macdLineBuffer[3];
double signalLineBuffer[3];
double closeBuffer[INDICATOR_BUFFER_SIZE];

//--- 缓存变量
static datetime lastIndicatorUpdate = 0;
static datetime lastBarTime = 0;
static bool indicatorsReady = false;

//--- EMA周期数组
int emaPeriods[EMA_COUNT] = {3, 5, 8, 10, 12, 15, 30, 35, 40, 45, 50, 60};

//--- 信号结构
struct SignalData
{
    bool gmmaSignal;
    bool supertrendSignal;
    bool macdSignal;
    bool buySignal;
    bool sellSignal;
};

//+------------------------------------------------------------------+
//| Expert initialization function                                   |
//+------------------------------------------------------------------+
int OnInit()
{
    Print("=== EA初始化开始 ===");
    Print("交易品种: ", _Symbol);
    Print("时间周期: ", _Period);
    Print("当前K线数: ", Bars(_Symbol, _Period));
    
    //--- 验证输入参数
    if(!ValidateInputParameters())
    {
        return(INIT_PARAMETERS_INCORRECT);
    }
    
    //--- 设置交易对象
    trade.SetExpertMagicNumber(MagicNumber);
    trade.SetDeviationInPoints(Slippage);
    trade.SetTypeFilling(ORDER_FILLING_FOK);
    
    //--- 创建指标句柄
    if(!CreateIndicatorHandles())
    {
        return(INIT_FAILED);
    }
    
    //--- 初始化缓冲区
    InitializeBuffers();
    
    //--- 检查交易权限
    if(!CheckTradingPermissions())
    {
        return(INIT_FAILED);
    }
    
    //--- 等待指标数据准备就绪
    if(!WaitForIndicatorData())
    {
        Print("警告：指标数据未完全准备就绪，将在运行中逐步准备");
    }
    
    Print("=== EA初始化完成 ===");
    Print("Livermore Strategy EA 优化版初始化成功");
    return(INIT_SUCCEEDED);
}

//+------------------------------------------------------------------+
//| 验证输入参数                                                    |
//+------------------------------------------------------------------+
bool ValidateInputParameters()
{
    Print("=== 参数验证开始 ===");
    Print("ATR_Period: ", ATR_Period);
    Print("SuperTrend_Factor: ", SuperTrend_Factor);
    Print("MACD_Fast: ", MACD_Fast);
    Print("MACD_Slow: ", MACD_Slow);
    Print("MACD_Signal: ", MACD_Signal);
    Print("LotSize: ", LotSize);
    Print("MaxRiskPercent: ", MaxRiskPercent);
    Print("MinBarsBetweenSignals: ", MinBarsBetweenSignals);
    
    if(ATR_Period <= 0 || SuperTrend_Factor <= 0 || MACD_Fast <= 0 || MACD_Slow <= 0 || MACD_Signal <= 0)
    {
        Print("错误：指标参数无效");
        Print("ATR_Period: ", ATR_Period, " (应该 > 0)");
        Print("SuperTrend_Factor: ", SuperTrend_Factor, " (应该 > 0)");
        Print("MACD_Fast: ", MACD_Fast, " (应该 > 0)");
        Print("MACD_Slow: ", MACD_Slow, " (应该 > 0)");
        Print("MACD_Signal: ", MACD_Signal, " (应该 > 0)");
        return false;
    }
    
    if(LotSize <= 0 || MaxRiskPercent < 0 || MaxRiskPercent > 100)
    {
        Print("错误：交易参数无效");
        Print("LotSize: ", LotSize, " (应该 > 0)");
        Print("MaxRiskPercent: ", MaxRiskPercent, " (应该在 0-100 之间)");
        return false;
    }
    
    if(MinBarsBetweenSignals < 1)
    {
        Print("错误：信号间隔参数无效");
        Print("MinBarsBetweenSignals: ", MinBarsBetweenSignals, " (应该 >= 1)");
        return false;
    }
    
    Print("=== 参数验证通过 ===");
    return true;
}

//+------------------------------------------------------------------+
//| 创建指标句柄                                                    |
//+------------------------------------------------------------------+
bool CreateIndicatorHandles()
{
    Print("=== 创建指标句柄开始 ===");
    Print("交易品种: ", _Symbol);
    Print("时间周期: ", _Period);
    
    Print("创建ATR指标句柄...");
    atrHandle = iATR(_Symbol, _Period, ATR_Period);
    if(atrHandle == INVALID_HANDLE)
    {
        Print("错误：无法创建ATR指标句柄，错误代码: ", GetLastError());
        Print("ATR参数: 周期=", ATR_Period);
        return false;
    }
    Print("ATR句柄创建成功: ", atrHandle);
    
    Print("创建MACD指标句柄...");
    macdHandle = iMACD(_Symbol, _Period, MACD_Fast, MACD_Slow, MACD_Signal, PRICE_CLOSE);
    if(macdHandle == INVALID_HANDLE)
    {
        Print("错误：无法创建MACD指标句柄，错误代码: ", GetLastError());
        Print("MACD参数: 快线=", MACD_Fast, ", 慢线=", MACD_Slow, ", 信号线=", MACD_Signal);
        return false;
    }
    Print("MACD句柄创建成功: ", macdHandle);
    
    Print("创建EMA指标句柄...");
    for(int i = 0; i < EMA_COUNT; i++)
    {
        emaHandles[i] = iMA(_Symbol, _Period, emaPeriods[i], 0, MODE_EMA, PRICE_CLOSE);
        if(emaHandles[i] == INVALID_HANDLE)
        {
            Print("错误：无法创建EMA", emaPeriods[i], "指标句柄，错误代码: ", GetLastError());
            return false;
        }
        Print("EMA", emaPeriods[i], "句柄创建成功: ", emaHandles[i]);
    }
    
    Print("=== 所有指标句柄创建成功 ===");
    return true;
}

//+------------------------------------------------------------------+
//| 初始化缓冲区                                                    |
//+------------------------------------------------------------------+
void InitializeBuffers()
{
    //--- 初始化数组
    ArrayInitialize(supertrendBuffer, 0);
    ArrayInitialize(gmmaShortBuffer, 0);
    ArrayInitialize(gmmaLongBuffer, 0);
    ArrayInitialize(macdLineBuffer, 0);
    ArrayInitialize(signalLineBuffer, 0);
    ArrayInitialize(closeBuffer, 0);
    
    Print("缓冲区初始化完成");
}

//+------------------------------------------------------------------+
//| 检查交易权限                                                    |
//+------------------------------------------------------------------+
bool CheckTradingPermissions()
{
    Print("=== 检查交易权限 ===");
    
    bool terminalTradeAllowed = TerminalInfoInteger(TERMINAL_TRADE_ALLOWED);
    bool mqlTradeAllowed = MQLInfoInteger(MQL_TRADE_ALLOWED);
    
    Print("终端交易权限: ", terminalTradeAllowed ? "允许" : "禁止");
    Print("EA交易权限: ", mqlTradeAllowed ? "允许" : "禁止");
    
    if(!terminalTradeAllowed)
    {
        Print("错误：终端不允许交易");
        return false;
    }
    
    if(!mqlTradeAllowed)
    {
        Print("错误：EA不允许交易");
        return false;
    }
    
    Print("=== 交易权限检查通过 ===");
    return true;
}

//+------------------------------------------------------------------+
//| 等待指标数据准备就绪                                            |
//+------------------------------------------------------------------+
bool WaitForIndicatorData()
{
    int maxWait = 10; // 最多等待10秒
    int waited = 0;
    
    while(waited < maxWait)
    {
        if(BarsCalculated(atrHandle) > ATR_Period && 
           BarsCalculated(macdHandle) > MACD_Slow)
        {
            bool allEmaReady = true;
            for(int i = 0; i < EMA_COUNT; i++)
            {
                if(BarsCalculated(emaHandles[i]) < emaPeriods[i])
                {
                    allEmaReady = false;
                    break;
                }
            }
            
            if(allEmaReady)
            {
                indicatorsReady = true;
                return true;
            }
        }
        
        Sleep(1000);
        waited++;
    }
    
    return false;
}

//+------------------------------------------------------------------+
//| Expert deinitialization function                                 |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
    //--- 释放指标句柄
    ReleaseHandle(atrHandle);
    ReleaseHandle(macdHandle);
    
    for(int i = 0; i < EMA_COUNT; i++)
    {
        ReleaseHandle(emaHandles[i]);
    }
    
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
    datetime currentBarTime = iTime(_Symbol, _Period, 0);
    bool isNewBar = (currentBarTime != lastBarTime);
    
    if(isNewBar)
    {
        lastBarTime = currentBarTime;
        // 只在新K线时更新指标
        if(!UpdateIndicatorsOptimized())
        {
            return; // 指标更新失败，跳过本次处理
        }
    }
    
    //--- 检查指标是否准备就绪
    if(!indicatorsReady)
    {
        return;
    }
    
    //--- 时间过滤
    if(UseTimeFilter && !IsTimeToTrade())
        return;
    
    //--- 检查是否有持仓
    hasPosition = CheckOurPosition();
    
    //--- 获取市场信号
    SignalData signals = AnalyzeMarketSignals();
    
    //--- 执行交易逻辑
    if(hasPosition)
    {
        if(signals.sellSignal)
        {
            ClosePosition();
        }
    }
    else if(signals.buySignal && CanOpenNewPosition())
    {
        OpenBuyPosition();
    }
}

//+------------------------------------------------------------------+
//| 优化的指标更新函数                                              |
//+------------------------------------------------------------------+
bool UpdateIndicatorsOptimized()
{
    static int updateCounter = 0;
    updateCounter++;
    
    //--- 每次只更新部分指标，分散计算负担
    bool success = true;
    
    switch(updateCounter % 3)
    {
        case 0:
            success = UpdateSuperTrend();
            break;
        case 1:
            success = UpdateGMMA();
            break;
        case 2:
            success = UpdateMACD();
            break;
    }
    
    // 标记指标已准备就绪
    if(success && !indicatorsReady)
    {
        indicatorsReady = true;
    }
    
    return success;
}

//+------------------------------------------------------------------+
//| 更新SuperTrend                                                  |
//+------------------------------------------------------------------+
bool UpdateSuperTrend()
{
    int copyCount = MathMin(INDICATOR_BUFFER_SIZE, 50); // 只复制最近50根K线
    
    double atrValues[], highValues[], lowValues[], tempClose[];
    
    if(CopyBuffer(atrHandle, 0, 0, copyCount, atrValues) < copyCount ||
       CopyHigh(_Symbol, _Period, 0, copyCount, highValues) < copyCount ||
       CopyLow(_Symbol, _Period, 0, copyCount, lowValues) < copyCount ||
       CopyClose(_Symbol, _Period, 0, copyCount, tempClose) < copyCount)
    {
        return false;
    }
    
    // 反转数组为时间序列
    ArraySetAsSeries(atrValues, true);
    ArraySetAsSeries(highValues, true);
    ArraySetAsSeries(lowValues, true);
    ArraySetAsSeries(tempClose, true);
    
    // 复制到全局缓冲区
    for(int i = 0; i < copyCount && i < INDICATOR_BUFFER_SIZE; i++)
    {
        closeBuffer[i] = tempClose[i];
    }
    
    // 计算SuperTrend
    for(int i = copyCount - 1; i >= 0 && i < INDICATOR_BUFFER_SIZE; i--)
    {
        double hl2 = (highValues[i] + lowValues[i]) / 2.0;
        double upperBand = hl2 + (SuperTrend_Factor * atrValues[i]);
        double lowerBand = hl2 - (SuperTrend_Factor * atrValues[i]);
        
        if(i == copyCount - 1)
        {
            supertrendBuffer[i] = lowerBand;
            continue;
        }
        
        if(closeBuffer[i] <= supertrendBuffer[i + 1])
            supertrendBuffer[i] = MathMin(upperBand, supertrendBuffer[i + 1]);
        else
            supertrendBuffer[i] = MathMax(lowerBand, supertrendBuffer[i + 1]);
    }
    
    return true;
}

//+------------------------------------------------------------------+
//| 更新GMMA                                                        |
//+------------------------------------------------------------------+
bool UpdateGMMA()
{
    int copyCount = MathMin(INDICATOR_BUFFER_SIZE, 30); // 只复制最近30根K线
    double emaValues[EMA_COUNT][30]; // 临时数组存储EMA值
    double tempBuffer[]; // 动态数组
    
    // 复制所有EMA数据
    for(int i = 0; i < EMA_COUNT; i++)
    {
        if(CopyBuffer(emaHandles[i], 0, 0, copyCount, tempBuffer) < copyCount)
        {
            return false;
        }
        ArraySetAsSeries(tempBuffer, true);
        
        // 复制到二维数组
        for(int j = 0; j < copyCount; j++)
        {
            emaValues[i][j] = tempBuffer[j];
        }
    }
    
    // 计算GMMA
    for(int bar = 0; bar < copyCount && bar < INDICATOR_BUFFER_SIZE; bar++)
    {
        // 短期GMMA (EMA 3,5,8,10,12,15)
        double shortSum = 0;
        for(int i = 0; i < 6; i++)
        {
            shortSum += emaValues[i][bar];
        }
        gmmaShortBuffer[bar] = shortSum / 6.0;
        
        // 长期GMMA (EMA 30,35,40,45,50,60)
        double longSum = 0;
        for(int i = 6; i < EMA_COUNT; i++)
        {
            longSum += emaValues[i][bar];
        }
        gmmaLongBuffer[bar] = longSum / 6.0;
    }
    
    return true;
}

//+------------------------------------------------------------------+
//| 更新MACD                                                        |
//+------------------------------------------------------------------+
bool UpdateMACD()
{
    double macdTmp[3], signalTmp[3];
    
    if(CopyBuffer(macdHandle, 0, 0, 3, macdTmp) < 3 || 
       CopyBuffer(macdHandle, 1, 0, 3, signalTmp) < 3)
    {
        return false;
    }
    
    // 反转为时间序列并存储
    for(int i = 0; i < 3; i++)
    {
        macdLineBuffer[i] = macdTmp[2-i];
        signalLineBuffer[i] = signalTmp[2-i];
    }
    
    return true;
}

//+------------------------------------------------------------------+
//| 分析市场信号                                                    |
//+------------------------------------------------------------------+
SignalData AnalyzeMarketSignals()
{
    SignalData signals = {0};
    
    signals.gmmaSignal = CheckGMMASignal();
    signals.supertrendSignal = CheckSupertrendSignal();
    signals.macdSignal = CheckMACDSignal();
    
    signals.buySignal = signals.gmmaSignal && signals.supertrendSignal;
    signals.sellSignal = CheckSellSignal();
    
    return signals;
}

//+------------------------------------------------------------------+
//| 检查GMMA信号                                                    |
//+------------------------------------------------------------------+
bool CheckGMMASignal()
{
    if(INDICATOR_BUFFER_SIZE < 3) return false;
    
    // GMMA上穿条件
    bool gmmaCrossUp = (gmmaShortBuffer[0] > gmmaLongBuffer[0]) && (gmmaShortBuffer[1] <= gmmaLongBuffer[1]);
    bool gmmaPrevCondition = (gmmaShortBuffer[1] <= gmmaLongBuffer[1]) || (gmmaShortBuffer[2] <= gmmaLongBuffer[2]);
    
    return gmmaCrossUp && gmmaPrevCondition;
}

//+------------------------------------------------------------------+
//| 检查SuperTrend信号                                              |
//+------------------------------------------------------------------+
bool CheckSupertrendSignal()
{
    if(INDICATOR_BUFFER_SIZE < 2) return false;
    
    double currentClose = SymbolInfoDouble(_Symbol, SYMBOL_BID);
    bool priceAboveSupertrend = currentClose > supertrendBuffer[0];
    bool supertrendRising = supertrendBuffer[0] > supertrendBuffer[1];
    
    return priceAboveSupertrend && supertrendRising;
}

//+------------------------------------------------------------------+
//| 检查MACD信号 - 修复逻辑错误                                     |
//+------------------------------------------------------------------+
bool CheckMACDSignal()
{
    // 修复后的MACD逻辑：只在MACD金叉时返回true
    bool macdCrossUp = (macdLineBuffer[0] > signalLineBuffer[0]) && (macdLineBuffer[1] <= signalLineBuffer[1]);
    return macdCrossUp;
}

//+------------------------------------------------------------------+
//| 检查卖出信号                                                    |
//+------------------------------------------------------------------+
bool CheckSellSignal()
{
    if(INDICATOR_BUFFER_SIZE < 3) return false;
    
    // GMMA下穿条件
    bool gmmaCrossDown = (gmmaShortBuffer[0] < gmmaLongBuffer[0]) && (gmmaShortBuffer[1] >= gmmaLongBuffer[1]);
    bool gmmaPrevConditionSell = gmmaShortBuffer[1] >= gmmaLongBuffer[1];
    bool gmmaSellSignal = gmmaCrossDown && gmmaPrevConditionSell;
    
    // SuperTrend卖出条件
    double currentClose = SymbolInfoDouble(_Symbol, SYMBOL_BID);
    bool priceBelowSupertrend = currentClose < supertrendBuffer[0];
    bool supertrendFalling = supertrendBuffer[0] < supertrendBuffer[1];
    bool supertrendSellSignal = priceBelowSupertrend && supertrendFalling;
    
    // MACD卖出条件 暂时不启用
    //bool macdCrossDown = (macdLineBuffer[0] < signalLineBuffer[0]) && (macdLineBuffer[1] >= signalLineBuffer[1]);
    
    return gmmaSellSignal && supertrendSellSignal;
}

//+------------------------------------------------------------------+
//| 检查是否可以开新仓                                              |
//+------------------------------------------------------------------+
bool CanOpenNewPosition()
{
    // 防止同一K线重复信号
    datetime currentBarTime = iTime(_Symbol, _Period, 0);
    if(currentBarTime == lastSignalTime)
        return false;
        
    // 防止信号过于频繁
    if(lastSignalTime > 0)
    {
        long timeDiff = (currentBarTime - lastSignalTime) / PeriodSeconds();
        if(timeDiff < MinBarsBetweenSignals)
            return false;
    }
    
    return true;
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
        lastSignalTime = iTime(_Symbol, _Period, 0); // 记录信号时间
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
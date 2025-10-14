//+------------------------------------------------------------------+
//|                                          LivermoreStrategyEA.mq5 |
//|                        Copyright 2024, MetaQuotes Software Corp. |
//|                                             https://www.mql5.com |
//+------------------------------------------------------------------+
#property copyright "Copyright 2024, MetaQuotes Software Corp."
#property link      "https://www.mql5.com"
#property version   "1.11"

#include <Trade\Trade.mqh>
#include <Trade\PositionInfo.mqh>

//--- 输入参数
input group "=== 策略参数 ==="
input int    ATR_Period = 10;           // ATR 周期
input double SuperTrend_Factor = 3.0;   // SuperTrend 因子

input group "=== 交易参数 ==="
input double LotSize = 0.1;             // 固定手数(当LotMode=FIXED时使用)
input int    MagicNumber = 123456;      // 魔术数字
input int    Slippage = 3;              // 滑点

input group "=== 风险管理 ==="
input bool   UseMaxHoldTime = false;   // 使用最大持仓时间

input group "=== 时间管理 ==="
input int    MaxHoldHours = 24;        // 最大持仓时间(小时)

input group "=== 手数计算模式 ==="
enum LOT_MODE
{
    FIXED = 0,          // 固定手数
    BALANCE_RATIO = 1   // 账户余额比例
};
input LOT_MODE LotMode = FIXED;                 // 手数计算模式
input double BalancePerLot = 50000.0;           // 每手所需账户余额(BALANCE_RATIO模式)
input double MaxLotSize = 10.0;                 // 最大手数限制
input double MinLotSize = 0.01;                 // 最小手数限制

input group "=== 时间过滤 ==="
input bool   UseTimeFilter = false;     // 使用时间过滤
input int    StartHour = 8;             // 开始小时
input int    EndHour = 18;              // 结束小时


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

//--- 平仓+反向开仓状态管理
enum PENDING_ACTION
{
    NONE = 0,           // 无待处理动作
    PENDING_SELL = 1,   // 等待开空仓
    PENDING_BUY = 2     // 等待开多仓
};
static PENDING_ACTION pendingAction = NONE;

//--- 指标句柄
int atrHandle;
int emaHandles[EMA_COUNT];

//--- 预分配缓冲区
double supertrendBuffer[INDICATOR_BUFFER_SIZE];
double gmmaShortBuffer[INDICATOR_BUFFER_SIZE];
double gmmaLongBuffer[INDICATOR_BUFFER_SIZE];
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
    bool buySignal;
    bool sellSignal;
};

//+------------------------------------------------------------------+
//| Expert initialization function                                   |
//+------------------------------------------------------------------+
int OnInit()
{
    Print("=== EA初始化开始 ===");
    Print("EA版本: v1.11 (无止损版本)");
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
        Print("警告:指标数据未完全准备就绪,将在运行中逐步准备");
    }
    
    //--- 显示手数计算模式
    PrintLotCalculationMode();
    
    Print("=== EA初始化完成 ===");
    Print("Livermore Strategy EA 优化版初始化成功(无止损)");
    return(INIT_SUCCEEDED);
}

//+------------------------------------------------------------------+
//| 打印手数计算模式信息                                            |
//+------------------------------------------------------------------+
void PrintLotCalculationMode()
{
    Print("=== 手数计算模式 ===");
    switch(LotMode)
    {
        case FIXED:
            Print("模式: 固定手数");
            Print("固定手数: ", LotSize);
            break;
        case BALANCE_RATIO:
            Print("模式: 账户余额比例");
            Print("每手所需余额: ", BalancePerLot);
            Print("当前账户余额: ", AccountInfoDouble(ACCOUNT_BALANCE));
            Print("预估手数: ", DoubleToString(AccountInfoDouble(ACCOUNT_BALANCE) / BalancePerLot, 2));
            break;
    }
    Print("手数限制: ", MinLotSize, " - ", MaxLotSize);
}

//+------------------------------------------------------------------+
//| 验证输入参数                                                    |
//+------------------------------------------------------------------+
bool ValidateInputParameters()
{
    Print("=== 参数验证开始 ===");
    Print("ATR_Period: ", ATR_Period);
    Print("SuperTrend_Factor: ", SuperTrend_Factor);
    Print("LotSize: ", LotSize);
    Print("LotMode: ", EnumToString(LotMode));
    
    if(ATR_Period <= 0 || SuperTrend_Factor <= 0)
    {
        Print("错误:指标参数无效");
        return false;
    }
    
    if(LotSize <= 0)
    {
        Print("错误:固定手数参数无效");
        return false;
    }
    
    if(BalancePerLot <= 0)
    {
        Print("错误:BalancePerLot参数无效");
        return false;
    }
    
    if(MaxLotSize < MinLotSize)
    {
        Print("错误:MaxLotSize不能小于MinLotSize");
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
        Print("错误:无法创建ATR指标句柄,错误代码: ", GetLastError());
        return false;
    }
    Print("ATR句柄创建成功: ", atrHandle);
    
    Print("创建EMA指标句柄...");
    for(int i = 0; i < EMA_COUNT; i++)
    {
        emaHandles[i] = iMA(_Symbol, _Period, emaPeriods[i], 0, MODE_EMA, PRICE_CLOSE);
        if(emaHandles[i] == INVALID_HANDLE)
        {
            Print("错误:无法创建EMA", emaPeriods[i], "指标句柄,错误代码: ", GetLastError());
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
    ArrayInitialize(supertrendBuffer, 0);
    ArrayInitialize(gmmaShortBuffer, 0);
    ArrayInitialize(gmmaLongBuffer, 0);
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
        Print("错误:终端不允许交易");
        return false;
    }
    
    if(!mqlTradeAllowed)
    {
        Print("错误:EA不允许交易");
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
    int maxWait = 10;
    int waited = 0;
    
    while(waited < maxWait)
    {
        if(BarsCalculated(atrHandle) > ATR_Period)
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
    //--- 检查新K线
    datetime currentBarTime = iTime(_Symbol, _Period, 0);
    bool isNewBar = (currentBarTime != lastBarTime);
    
    if(isNewBar)
    {
        lastBarTime = currentBarTime;
        
        // 只在新K线时一次性更新所有指标
        if(!UpdateAllIndicators())
        {
            return;
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
    
    // 首先检查是否有待处理的反向开仓动作
    if(!hasPosition && pendingAction != NONE)
    {
        if(pendingAction == PENDING_BUY && CanOpenReversePosition())
        {
            Print("执行待处理的开多仓动作");
            OpenBuyPosition();
            pendingAction = NONE;
        }
        else if(pendingAction == PENDING_SELL && CanOpenReversePosition())
        {
            Print("执行待处理的开空仓动作");
            OpenSellPosition();
            pendingAction = NONE;
        }
        return; // 处理完待处理动作后返回
    }
    
    if(hasPosition)
    {
        // 获取当前持仓方向
        bool isLongPosition = IsLongPosition();
        
        // 根据持仓方向检查反向信号,实现平仓+反向开仓
        if(isLongPosition && signals.sellSignal)
        {
            Print("检测到做空信号,平多仓并标记开空仓");
            ClosePosition();
            pendingAction = PENDING_SELL; // 标记下次tick开空仓
        }
        else if(!isLongPosition && signals.buySignal)
        {
            Print("检测到买入信号,平空仓并标记开多仓");
            ClosePosition();
            pendingAction = PENDING_BUY; // 标记下次tick开多仓
        }
    }
    else
    {
        // 没有持仓时,检查开仓信号
        if(signals.buySignal && CanOpenNewPosition())
        {
            Print("检测到买入信号,准备开多仓");
            OpenBuyPosition();
        }
        else if(signals.sellSignal && CanOpenNewPosition())
        {
            Print("检测到做空信号,准备开空仓");
            OpenSellPosition();
        }
    }
}

//+------------------------------------------------------------------+
//| 一次性更新所有指标（替代原来的分批更新）                          |
//+------------------------------------------------------------------+
bool UpdateAllIndicators()
{
    bool success = true;
    
    // 同时更新所有指标，确保数据同步
    success &= UpdateSuperTrend();
    success &= UpdateGMMA();
    
    if(success && !indicatorsReady)
    {
        indicatorsReady = true;
        Print("所有指标更新完成并准备就绪");
    }
    
    return success;
}

//+------------------------------------------------------------------+
//| 更新SuperTrend                                                  |
//+------------------------------------------------------------------+
bool UpdateSuperTrend()
{
    Print("=== 开始更新SuperTrend ===");
    int copyCount = MathMin(INDICATOR_BUFFER_SIZE, 50);
    Print("复制数据数量: ", copyCount);
    
    double atrValues[], highValues[], lowValues[], tempClose[];
    
    if(CopyBuffer(atrHandle, 0, 0, copyCount, atrValues) < copyCount ||
       CopyHigh(_Symbol, _Period, 0, copyCount, highValues) < copyCount ||
       CopyLow(_Symbol, _Period, 0, copyCount, lowValues) < copyCount ||
       CopyClose(_Symbol, _Period, 0, copyCount, tempClose) < copyCount)
    {
        Print("✗ SuperTrend数据复制失败");
        return false;
    }
    
    ArraySetAsSeries(atrValues, true);
    ArraySetAsSeries(highValues, true);
    ArraySetAsSeries(lowValues, true);
    ArraySetAsSeries(tempClose, true);
    
    for(int i = 0; i < copyCount && i < INDICATOR_BUFFER_SIZE; i++)
    {
        closeBuffer[i] = tempClose[i];
    }
    
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
    
    // 打印关键数据点 (最近3根K线)
    Print("SuperTrend[0] (当前): ", DoubleToString(supertrendBuffer[0], _Digits));
    Print("SuperTrend[1] (上一根): ", DoubleToString(supertrendBuffer[1], _Digits));
    Print("SuperTrend[2] (上上根): ", DoubleToString(supertrendBuffer[2], _Digits));
    Print("Close[0]: ", DoubleToString(closeBuffer[0], _Digits));
    Print("Close[1]: ", DoubleToString(closeBuffer[1], _Digits));
    Print("ATR[0]: ", DoubleToString(atrValues[0], _Digits));
    Print("SuperTrend因子: ", SuperTrend_Factor);
    
    // 判断趋势方向
    bool isUptrend = closeBuffer[1] > supertrendBuffer[1];
    bool isRising = supertrendBuffer[1] > supertrendBuffer[2];
    Print("SuperTrend趋势: ", isUptrend ? "上升" : "下降");
    Print("SuperTrend方向: ", isRising ? "上涨" : "下跌");
    Print("✓ SuperTrend更新完成");
    
    return true;
}

//+------------------------------------------------------------------+
//| 更新GMMA                                                        |
//+------------------------------------------------------------------+
bool UpdateGMMA()
{
    Print("=== 开始更新GMMA ===");
    int copyCount = MathMin(INDICATOR_BUFFER_SIZE, 30);
    Print("复制数据数量: ", copyCount);
    
    double emaValues[EMA_COUNT][30];
    double tempBuffer[];
    
    for(int i = 0; i < EMA_COUNT; i++)
    {
        if(CopyBuffer(emaHandles[i], 0, 0, copyCount, tempBuffer) < copyCount)
        {
            Print("✗ GMMA EMA", emaPeriods[i], " 数据复制失败");
            return false;
        }
        ArraySetAsSeries(tempBuffer, true);
        
        for(int j = 0; j < copyCount; j++)
        {
            emaValues[i][j] = tempBuffer[j];
        }
    }
    Print("✓ 所有EMA数据复制成功");
    
    for(int bar = 0; bar < copyCount && bar < INDICATOR_BUFFER_SIZE; bar++)
    {
        double shortSum = 0;
        for(int i = 0; i < 6; i++)
        {
            shortSum += emaValues[i][bar];
        }
        gmmaShortBuffer[bar] = shortSum / 6.0;
        
        double longSum = 0;
        for(int i = 6; i < EMA_COUNT; i++)
        {
            longSum += emaValues[i][bar];
        }
        gmmaLongBuffer[bar] = longSum / 6.0;
    }
    
    // 打印关键数据点 (最近3根K线)
    Print("--- GMMA短期组 (EMA3-15平均) ---");
    Print("GMMA短期[0] (当前): ", DoubleToString(gmmaShortBuffer[0], _Digits));
    Print("GMMA短期[1] (上一根): ", DoubleToString(gmmaShortBuffer[1], _Digits));
    Print("GMMA短期[2] (上上根): ", DoubleToString(gmmaShortBuffer[2], _Digits));
    
    Print("--- GMMA长期组 (EMA30-60平均) ---");
    Print("GMMA长期[0] (当前): ", DoubleToString(gmmaLongBuffer[0], _Digits));
    Print("GMMA长期[1] (上一根): ", DoubleToString(gmmaLongBuffer[1], _Digits));
    Print("GMMA长期[2] (上上根): ", DoubleToString(gmmaLongBuffer[2], _Digits));
    
    // 打印EMA原始值 (第1根K线)
    Print("--- EMA原始值 [1] ---");
    string emaShortStr = "";
    for(int i = 0; i < 6; i++)
    {
        emaShortStr += "EMA" + IntegerToString(emaPeriods[i]) + "=" + DoubleToString(emaValues[i][1], _Digits) + " ";
    }
    Print("短期组: ", emaShortStr);
    
    string emaLongStr = "";
    for(int i = 6; i < EMA_COUNT; i++)
    {
        emaLongStr += "EMA" + IntegerToString(emaPeriods[i]) + "=" + DoubleToString(emaValues[i][1], _Digits) + " ";
    }
    Print("长期组: ", emaLongStr);
    
    // 判断GMMA关系
    bool shortAboveLong_0 = gmmaShortBuffer[0] > gmmaLongBuffer[0];
    bool shortAboveLong_1 = gmmaShortBuffer[1] > gmmaLongBuffer[1];
    bool shortAboveLong_2 = gmmaShortBuffer[2] > gmmaLongBuffer[2];
    
    Print("GMMA关系[0]: 短期", shortAboveLong_0 ? ">" : "<=", "长期");
    Print("GMMA关系[1]: 短期", shortAboveLong_1 ? ">" : "<=", "长期");
    Print("GMMA关系[2]: 短期", shortAboveLong_2 ? ">" : "<=", "长期");
    
    // 检测交叉
    bool crossUp = (gmmaShortBuffer[1] > gmmaLongBuffer[1]) && (gmmaShortBuffer[2] <= gmmaLongBuffer[2]);
    bool crossDown = (gmmaShortBuffer[1] < gmmaLongBuffer[1]) && (gmmaShortBuffer[2] >= gmmaLongBuffer[2]);
    
    if(crossUp)
        Print(">>> 检测到GMMA金叉 (短期上穿长期) <<<");
    else if(crossDown)
        Print(">>> 检测到GMMA死叉 (短期下穿长期) <<<");
    else
        Print("GMMA状态: 无交叉");
    
    Print("✓ GMMA更新完成");
    
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
    
    // 买入信号:GMMA上穿 + SuperTrend上升
    signals.buySignal = signals.gmmaSignal && signals.supertrendSignal;
    
    // 做空信号:GMMA下穿 + SuperTrend下降
    signals.sellSignal = CheckShortSignal();
    
    return signals;
}

//+------------------------------------------------------------------+
//| 检查GMMA信号（使用已确认K线）                                    |
//+------------------------------------------------------------------+
bool CheckGMMASignal()
{
    if(INDICATOR_BUFFER_SIZE < 3) return false;
    
    // 使用已确认的K线 [1] 和 [2]
    bool gmmaCrossUp = (gmmaShortBuffer[1] > gmmaLongBuffer[1]) && 
                       (gmmaShortBuffer[2] <= gmmaLongBuffer[2]);
    bool gmmaPrevCondition = (gmmaShortBuffer[2] <= gmmaLongBuffer[2]) || 
                             (gmmaShortBuffer[3] <= gmmaLongBuffer[3]);
    
    return gmmaCrossUp && gmmaPrevCondition;
}

//+------------------------------------------------------------------+
//| 检查SuperTrend信号（使用已确认K线）                              |
//+------------------------------------------------------------------+
bool CheckSupertrendSignal()
{
    if(INDICATOR_BUFFER_SIZE < 3) return false;
    
    // 使用已完成的K线 [1] 和 [2]，而不是当前K线 [0]
    double prevClose = iClose(_Symbol, _Period, 1);
    bool priceAboveSupertrend = prevClose > supertrendBuffer[1];
    bool supertrendRising = supertrendBuffer[1] > supertrendBuffer[2];
    
    return priceAboveSupertrend && supertrendRising;
}


//+------------------------------------------------------------------+
//| 检查做空信号（使用已确认K线）                                    |
//+------------------------------------------------------------------+
bool CheckShortSignal()
{
    if(INDICATOR_BUFFER_SIZE < 3) return false;
    
    // GMMA下穿条件 - 使用已确认的K线 [1] 和 [2]
    bool gmmaCrossDown = (gmmaShortBuffer[1] < gmmaLongBuffer[1]) && 
                         (gmmaShortBuffer[2] >= gmmaLongBuffer[2]);
    bool gmmaPrevConditionSell = gmmaShortBuffer[2] >= gmmaLongBuffer[2];
    bool gmmaShortSignal = gmmaCrossDown && gmmaPrevConditionSell;
    
    // SuperTrend下降条件 - 使用已确认的K线收盘价
    double prevClose = iClose(_Symbol, _Period, 1);
    bool priceBelowSupertrend = prevClose < supertrendBuffer[1];
    
    // 计算SuperTrend方向: [1] < [2] 表示下降趋势
    bool supertrendFalling = supertrendBuffer[1] < supertrendBuffer[2];
    bool supertrendShortSignal = priceBelowSupertrend && supertrendFalling;
    
    return gmmaShortSignal && supertrendShortSignal;
}

//+------------------------------------------------------------------+
//| 检查是否可以开新仓                                              |
//+------------------------------------------------------------------+
bool CanOpenNewPosition()
{
    datetime currentBarTime = iTime(_Symbol, _Period, 0);
    if(currentBarTime == lastSignalTime)
        return false;
        
    return true;
}

//+------------------------------------------------------------------+
//| 检查是否可以执行反向开仓(忽略同一K线限制)                    |
//+------------------------------------------------------------------+
bool CanOpenReversePosition()
{
    // 反向开仓不受同一K线限制,因为这是平仓后的反向操作
    return true;
}

//+------------------------------------------------------------------+
//| 检查当前持仓是否为多头                                          |
//+------------------------------------------------------------------+
bool IsLongPosition()
{
    for(int i = PositionsTotal() - 1; i >= 0; i--)
    {
        if(positionInfo.SelectByIndex(i))
        {
            if(positionInfo.Symbol() == _Symbol && 
               positionInfo.Magic() == MagicNumber)
            {
                return (positionInfo.PositionType() == POSITION_TYPE_BUY);
            }
        }
    }
    return false; // 没有持仓
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
//| 检查最大持仓时间                                                |
//+------------------------------------------------------------------+
bool CheckMaxHoldTime()
{
    if(!hasPosition) return false;
    
    datetime currentTime = TimeCurrent();
    long holdTimeSeconds = currentTime - lastBuyTime;
    long maxHoldSeconds = MaxHoldHours * 3600;
    
    if(holdTimeSeconds >= maxHoldSeconds)
    {
        Print("持仓时间: ", holdTimeSeconds/3600.0, " 小时,超过最大限制: ", MaxHoldHours, " 小时");
        return true;
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
    
    // 检查手数是否有效
    if(lot <= 0)
    {
        Print("错误:计算的手数无效: ", lot);
        return;
    }
    
    // 不设置止损止盈
    double sl = 0;
    double tp = 0;
    
    // 显示保证金信息
    ShowMarginInfo(lot, ask);
    
    Print("=== 准备开多仓 ===");
    Print("当前价格(ASK): ", ask);
    Print("计算手数: ", lot);
    Print("止损: 无");
    Print("止盈: 无");
    Print("手数模式: ", EnumToString(LotMode));
    
    if(trade.Buy(lot, _Symbol, ask, sl, tp, "Livermore Strategy Buy"))
    {
        lastBuyPrice = ask;
        lastBuyTime = TimeCurrent();
        lastSignalTime = iTime(_Symbol, _Period, 0);
        hasPosition = true;
        totalTrades++;
        
        Print("✓ 开多仓成功 - 价格: ", ask, ", 手数: ", lot);
    }
    else
    {
        uint error = GetLastError();    
        Print("✗ 开多仓失败 - 错误代码: ", error, ", 描述: ", ErrorDescription(error));
    }
}

//+------------------------------------------------------------------+
//| 开空仓                                                          |
//+------------------------------------------------------------------+
void OpenSellPosition()
{
    double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
    double lot = CalculateLotSize();
    
    // 检查手数是否有效
    if(lot <= 0)
    {
        Print("错误:计算的手数无效: ", lot);
        return;
    }
    
    // 不设置止损止盈
    double sl = 0;
    double tp = 0;
    
    // 显示保证金信息
    ShowMarginInfo(lot, bid);
    
    Print("=== 准备开空仓 ===");
    Print("当前价格(BID): ", bid);
    Print("计算手数: ", lot);
    Print("止损: 无");
    Print("止盈: 无");
    Print("手数模式: ", EnumToString(LotMode));
    
    if(trade.Sell(lot, _Symbol, bid, sl, tp, "Livermore Strategy Sell"))
    {
        lastBuyPrice = bid;
        lastBuyTime = TimeCurrent();
        lastSignalTime = iTime(_Symbol, _Period, 0);
        hasPosition = true;
        totalTrades++;
        
        Print("✓ 开空仓成功 - 价格: ", bid, ", 手数: ", lot);
    }
    else
    {
        uint error = GetLastError();    
        Print("✗ 开空仓失败 - 错误代码: ", error, ", 描述: ", ErrorDescription(error));
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
        
        Print("✓ 平仓成功 - 盈亏: ", DoubleToString(profit, 2), ", 累计盈亏: ", DoubleToString(totalProfit, 2));
    }
    else
    {
        uint error = GetLastError();
        Print("✗ 平仓失败 - 错误代码: ", error, ", 描述: ", ErrorDescription(error));
    }
}

//+------------------------------------------------------------------+
//| 显示保证金信息                                                  |
//+------------------------------------------------------------------+
void ShowMarginInfo(double lot, double price)
{
    double requiredMargin = 0;
    double accountBalance = AccountInfoDouble(ACCOUNT_BALANCE);
    double accountFreeMargin = AccountInfoDouble(ACCOUNT_MARGIN_FREE);
    
    if(OrderCalcMargin(ORDER_TYPE_BUY, _Symbol, 1.0, price, requiredMargin))
    {
        Print("=== 保证金信息 ===");
        Print("1手所需保证金: $", DoubleToString(requiredMargin, 2));
        Print("当前手数: ", lot);
        Print("本次所需保证金: $", DoubleToString(requiredMargin * lot, 2));
        Print("账户余额: $", DoubleToString(accountBalance, 2));
        Print("可用保证金: $", DoubleToString(accountFreeMargin, 2));
        
        double marginRatio = (requiredMargin * lot) / accountBalance * 100;
        Print("保证金占用比例: ", DoubleToString(marginRatio, 2), "%");
        
        if(marginRatio > 80)
        {
            Print("⚠ 严重警告:保证金占用超过80%,强烈建议减少手数!");
        }
        else if(marginRatio > 50)
        {
            Print("⚠ 警告:保证金占用过高,建议减少手数");
        }
        else if(marginRatio > 30)
        {
            Print("⚠ 注意:保证金占用较高,请谨慎交易");
        }
        else
        {
            Print("✓ 保证金占用合理");
        }
        
        // 显示预估盈亏信息
        double pointValue = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
        Print("每点价值: $", DoubleToString(pointValue * lot, 2));
    }
    else
    {
        Print("⚠ 无法计算保证金信息");
    }
}

//+------------------------------------------------------------------+
//| 计算手数 - 修复版                                               |
//+------------------------------------------------------------------+
double CalculateLotSize()
{
    double accountBalance = AccountInfoDouble(ACCOUNT_BALANCE);
    double calculatedLot = 0;
    
    Print("=== 开始计算手数 ===");
    Print("账户余额: $", DoubleToString(accountBalance, 2));
    Print("手数模式: ", EnumToString(LotMode));
    
    // 根据不同模式计算手数
    switch(LotMode)
    {
        case FIXED:
            // 固定手数模式
            calculatedLot = LotSize;
            Print("固定手数: ", calculatedLot);
            break;
            
        case BALANCE_RATIO:
            // 账户余额比例模式
            calculatedLot = accountBalance / BalancePerLot;
            Print("每手所需余额: $", BalancePerLot);
            Print("计算手数 (余额/比例): ", calculatedLot);
            break;
    }
    
    //--- 标准化手数并应用限制
    double minLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
    double maxLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
    double lotStep = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
    
    Print("交易品种手数限制: 最小=", minLot, ", 最大=", maxLot, ", 步长=", lotStep);
    Print("用户手数限制: 最小=", MinLotSize, ", 最大=", MaxLotSize);
    
    // 应用用户自定义的最小最大限制
    calculatedLot = MathMax(calculatedLot, MinLotSize);
    calculatedLot = MathMin(calculatedLot, MaxLotSize);
    
    // 应用交易品种的限制
    calculatedLot = MathMax(calculatedLot, minLot);
    calculatedLot = MathMin(calculatedLot, maxLot);
    
    // 标准化到正确的步长
    calculatedLot = NormalizeDouble(MathFloor(calculatedLot / lotStep) * lotStep, 2);
    
    // 最终检查
    if(calculatedLot < minLot)
    {
        Print("⚠ 警告:计算手数小于最小值,使用最小手数: ", minLot);
        calculatedLot = minLot;
    }
    
    Print("最终手数: ", calculatedLot);
    Print("===================");
    
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
        case 1:     return "没有错误,但结果未知";
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
        case 145:   return "修改被拒绝,因为订单太接近市场";
        case 146:   return "交易环境忙";
        case 147:   return "止损/止盈被经纪人禁止";
        case 148:   return "订单数量过多";
        case 149:   return "对冲被禁止";
        case 150:   return "禁止通过FIFO规则平仓";
        default:    return "未知错误";
    }
}
//+------------------------------------------------------------------+
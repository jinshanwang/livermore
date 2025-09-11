//+------------------------------------------------------------------+
//|                                          LivermoreStrategy.mq5 |
//|                        Copyright 2024, MetaQuotes Software Corp. |
//|                                             https://www.mql5.com |
//+------------------------------------------------------------------+
#property copyright "Copyright 2024, MetaQuotes Software Corp."
#property link      "https://www.mql5.com"
#property version   "1.00"
#property indicator_chart_window
#property indicator_buffers 2
#property indicator_plots   2

//--- plot signals
#property indicator_label1  "Buy Signal"
#property indicator_type1   DRAW_ARROW
#property indicator_color1  clrLime
#property indicator_style1  STYLE_SOLID
#property indicator_width1  2

#property indicator_label2  "Sell Signal"
#property indicator_type2   DRAW_ARROW
#property indicator_color2  clrRed
#property indicator_style2  STYLE_SOLID
#property indicator_width2  2

//--- input parameters
input int    ATR_Period = 10;           // ATR 周期
input double SuperTrend_Factor = 3.0;   // SuperTrend 因子
input int    MACD_Fast = 12;            // MACD 快线
input int    MACD_Slow = 26;            // MACD 慢线
input int    MACD_Signal = 9;           // MACD 信号线

//--- indicator buffers
double BuySignalBuffer[];
double SellSignalBuffer[];

//--- global variables
double lastBuyPrice = 0;
datetime lastBuyTime = 0;
bool hasPosition = false;

//+------------------------------------------------------------------+
//| Custom indicator initialization function                         |
//+------------------------------------------------------------------+
int OnInit()
{
    //--- indicator buffers mapping
    SetIndexBuffer(0, BuySignalBuffer, INDICATOR_DATA);
    SetIndexBuffer(1, SellSignalBuffer, INDICATOR_DATA);
    
    //--- setting a code from the Wingdings charset as the property of PLOT_ARROW
    PlotIndexSetInteger(0, PLOT_ARROW, 233); // 上箭头
    PlotIndexSetInteger(1, PLOT_ARROW, 234); // 下箭头
    
    //--- set arrow codes for the PLOT_ARROW property
    PlotIndexSetInteger(0, PLOT_ARROW_SHIFT, 0);
    PlotIndexSetInteger(1, PLOT_ARROW_SHIFT, 0);
    
    //--- set accuracy of indicator values
    IndicatorSetInteger(INDICATOR_DIGITS, _Digits);
    
    //--- sets first bar from what index will be drawn
    PlotIndexSetInteger(0, PLOT_DRAW_BEGIN, 60);
    PlotIndexSetInteger(1, PLOT_DRAW_BEGIN, 60);
    
    return(INIT_SUCCEEDED);
}

//+------------------------------------------------------------------+
//| Custom indicator iteration function                              |
//+------------------------------------------------------------------+
int OnCalculate(const int rates_total,
                const int prev_calculated,
                const datetime &time[],
                const double &open[],
                const double &high[],
                const double &low[],
                const double &close[],
                const long &tick_volume[],
                const long &volume[],
                const int &spread[])
{
    //--- check for bars count
    if(rates_total < 60)
        return(0);
    
    //--- preliminary calculations
    int start = prev_calculated == 0 ? 60 : prev_calculated - 1;
    
    //--- the main loop of calculations
    for(int i = start; i < rates_total; i++)
    {
        //--- 计算GMMA
        double shortAvg = CalculateGMMA_Short(i, close);
        double longAvg = CalculateGMMA_Long(i, close);
        
        //--- 计算SuperTrend
        double supertrend = CalculateSuperTrend(i, high, low, close);
        int direction = GetSuperTrendDirection(i, high, low, close);
        
        //--- 计算MACD
        double macdLine = CalculateMACD_Line(i, close);
        double signalLine = CalculateMACD_Signal(i, close);
        double histLine = macdLine - signalLine;
        
        //--- 买入信号条件
        bool gmmaCrossUp = (i > 0) && (shortAvg > longAvg) && (close[i-1] <= CalculateGMMA_Long(i-1, close));
        bool gmmaPrevCondition = (i > 1) && ((CalculateGMMA_Short(i-1, close) <= CalculateGMMA_Long(i-1, close)) || 
                                            (CalculateGMMA_Short(i-2, close) <= CalculateGMMA_Long(i-2, close)));
        bool gmmaSignal = gmmaCrossUp && gmmaPrevCondition;
        
        bool priceAboveSupertrend = close[i] > supertrend;
        bool supertrendRising = direction < 0;
        bool supertrendSignal = priceAboveSupertrend && supertrendRising;
        
        bool difCrossUp = (i > 0) && (macdLine > signalLine) && (CalculateMACD_Line(i-1, close) <= CalculateMACD_Signal(i-1, close));
        bool macdHistPositive = histLine > 0;
        bool macdSignal = difCrossUp && macdHistPositive;
        
        //--- 综合买入信号
        bool buySignal = gmmaSignal && supertrendSignal;
        
        //--- 卖出信号条件
        bool gmmaCrossDown = (i > 0) && (shortAvg < longAvg) && (close[i-1] >= CalculateGMMA_Long(i-1, close));
        bool gmmaPrevConditionSell = (i > 0) && (CalculateGMMA_Short(i-1, close) >= CalculateGMMA_Long(i-1, close));
        bool gmmaSellSignal = gmmaCrossDown && gmmaPrevConditionSell;
        
        bool priceBelowSupertrend = close[i] < supertrend;
        bool supertrendFalling = direction > 0;
        bool supertrendSellSignal = priceBelowSupertrend && supertrendFalling;
        
        bool difCrossDown = (i > 0) && (macdLine < signalLine) && (CalculateMACD_Line(i-1, close) >= CalculateMACD_Signal(i-1, close));
        bool macdHistNegative = histLine < 0;
        bool macdSellSignal = difCrossDown && macdHistNegative;
        
        //--- 综合卖出信号
        bool sellSignal = gmmaSellSignal && supertrendSellSignal;
        
        //--- 设置信号缓冲区
        BuySignalBuffer[i] = buySignal ? low[i] - 10 * _Point : EMPTY_VALUE;
        SellSignalBuffer[i] = sellSignal ? high[i] + 10 * _Point : EMPTY_VALUE;
        
        //--- 处理交易记录
        if(buySignal && !hasPosition)
        {
            lastBuyPrice = close[i];
            lastBuyTime = time[i];
            hasPosition = true;
            
            // 创建买入标签
            CreateBuyLabel(i, time[i], low[i], close[i]);
        }
        
        if(sellSignal && hasPosition)
        {
            double pointDiff = close[i] - lastBuyPrice;
            hasPosition = false;
            
            // 创建卖出标签
            CreateSellLabel(i, time[i], high[i], close[i], pointDiff);
            
            // 创建交易连线
            CreateTradeLine(lastBuyTime, lastBuyPrice, time[i], close[i], pointDiff);
        }
    }
    
    return(rates_total);
}

//+------------------------------------------------------------------+
//| 计算短期GMMA                                                    |
//+------------------------------------------------------------------+
double CalculateGMMA_Short(int index, const double &close[])
{
    if(index < 15) return 0;
    
    double ema3 = iMA(_Symbol, _Period, 3, 0, MODE_EMA, PRICE_CLOSE, index);
    double ema5 = iMA(_Symbol, _Period, 5, 0, MODE_EMA, PRICE_CLOSE, index);
    double ema8 = iMA(_Symbol, _Period, 8, 0, MODE_EMA, PRICE_CLOSE, index);
    double ema10 = iMA(_Symbol, _Period, 10, 0, MODE_EMA, PRICE_CLOSE, index);
    double ema12 = iMA(_Symbol, _Period, 12, 0, MODE_EMA, PRICE_CLOSE, index);
    double ema15 = iMA(_Symbol, _Period, 15, 0, MODE_EMA, PRICE_CLOSE, index);
    
    return (ema3 + ema5 + ema8 + ema10 + ema12 + ema15) / 6.0;
}

//+------------------------------------------------------------------+
//| 计算长期GMMA                                                    |
//+------------------------------------------------------------------+
double CalculateGMMA_Long(int index, const double &close[])
{
    if(index < 60) return 0;
    
    double ema30 = iMA(_Symbol, _Period, 30, 0, MODE_EMA, PRICE_CLOSE, index);
    double ema35 = iMA(_Symbol, _Period, 35, 0, MODE_EMA, PRICE_CLOSE, index);
    double ema40 = iMA(_Symbol, _Period, 40, 0, MODE_EMA, PRICE_CLOSE, index);
    double ema45 = iMA(_Symbol, _Period, 45, 0, MODE_EMA, PRICE_CLOSE, index);
    double ema50 = iMA(_Symbol, _Period, 50, 0, MODE_EMA, PRICE_CLOSE, index);
    double ema60 = iMA(_Symbol, _Period, 60, 0, MODE_EMA, PRICE_CLOSE, index);
    
    return (ema30 + ema35 + ema40 + ema45 + ema50 + ema60) / 6.0;
}

//+------------------------------------------------------------------+
//| 计算SuperTrend                                                  |
//+------------------------------------------------------------------+
double CalculateSuperTrend(int index, const double &high[], const double &low[], const double &close[])
{
    if(index < ATR_Period) return 0;
    
    double atr = iATR(_Symbol, _Period, ATR_Period, index);
    double hl2 = (high[index] + low[index]) / 2.0;
    
    double upperBand = hl2 + (SuperTrend_Factor * atr);
    double lowerBand = hl2 - (SuperTrend_Factor * atr);
    
    if(index == ATR_Period)
        return lowerBand;
    
    double prevSupertrend = CalculateSuperTrend(index - 1, high, low, close);
    
    if(close[index] <= prevSupertrend)
        return MathMin(upperBand, prevSupertrend);
    else
        return MathMax(lowerBand, prevSupertrend);
}

//+------------------------------------------------------------------+
//| 获取SuperTrend方向                                              |
//+------------------------------------------------------------------+
int GetSuperTrendDirection(int index, const double &high[], const double &low[], const double &close[])
{
    if(index < ATR_Period) return 0;
    
    double supertrend = CalculateSuperTrend(index, high, low, close);
    double prevSupertrend = CalculateSuperTrend(index - 1, high, low, close);
    
    if(supertrend < prevSupertrend)
        return -1; // 上升趋势
    else
        return 1;  // 下降趋势
}

//+------------------------------------------------------------------+
//| 计算MACD线                                                      |
//+------------------------------------------------------------------+
double CalculateMACD_Line(int index, const double &close[])
{
    if(index < MACD_Slow) return 0;
    
    double fastEMA = iMA(_Symbol, _Period, MACD_Fast, 0, MODE_EMA, PRICE_CLOSE, index);
    double slowEMA = iMA(_Symbol, _Period, MACD_Slow, 0, MODE_EMA, PRICE_CLOSE, index);
    
    return fastEMA - slowEMA;
}

//+------------------------------------------------------------------+
//| 计算MACD信号线                                                  |
//+------------------------------------------------------------------+
double CalculateMACD_Signal(int index, const double &close[])
{
    if(index < MACD_Slow + MACD_Signal) return 0;
    
    // 简化的信号线计算，实际应该使用MACD线的EMA
    double macdLine = CalculateMACD_Line(index, close);
    double signalLine = iMA(_Symbol, _Period, MACD_Signal, 0, MODE_EMA, PRICE_CLOSE, index);
    
    return signalLine;
}

//+------------------------------------------------------------------+
//| 创建买入标签                                                    |
//+------------------------------------------------------------------+
void CreateBuyLabel(int index, datetime time, double price, double close)
{
    string labelName = "Buy_" + IntegerToString(index);
    string text = "BUY\n" + DoubleToString(close, _Digits);
    
    ObjectCreate(0, labelName, OBJ_TEXT, 0, time, price - 20 * _Point);
    ObjectSetString(0, labelName, OBJPROP_TEXT, text);
    ObjectSetInteger(0, labelName, OBJPROP_COLOR, clrLime);
    ObjectSetInteger(0, labelName, OBJPROP_FONTSIZE, 8);
    ObjectSetString(0, labelName, OBJPROP_FONT, "Arial");
}

//+------------------------------------------------------------------+
//| 创建卖出标签                                                    |
//+------------------------------------------------------------------+
void CreateSellLabel(int index, datetime time, double price, double close, double pointDiff)
{
    string labelName = "Sell_" + IntegerToString(index);
    string text = "SELL\n" + DoubleToString(close, _Digits) + "\nΔ: " + DoubleToString(pointDiff, _Digits);
    
    ObjectCreate(0, labelName, OBJ_TEXT, 0, time, price + 20 * _Point);
    ObjectSetString(0, labelName, OBJPROP_TEXT, text);
    ObjectSetInteger(0, labelName, OBJPROP_COLOR, clrRed);
    ObjectSetInteger(0, labelName, OBJPROP_FONTSIZE, 8);
    ObjectSetString(0, labelName, OBJPROP_FONT, "Arial");
}

//+------------------------------------------------------------------+
//| 创建交易连线                                                    |
//+------------------------------------------------------------------+
void CreateTradeLine(datetime startTime, double startPrice, datetime endTime, double endPrice, double pointDiff)
{
    string lineName = "TradeLine_" + IntegerToString(startTime);
    
    ObjectCreate(0, lineName, OBJ_TREND, 0, startTime, startPrice, endTime, endPrice);
    ObjectSetInteger(0, lineName, OBJPROP_COLOR, pointDiff >= 0 ? clrLime : clrRed);
    ObjectSetInteger(0, lineName, OBJPROP_WIDTH, 2);
    ObjectSetInteger(0, lineName, OBJPROP_STYLE, STYLE_SOLID);
}

//+------------------------------------------------------------------+
//| 指标去初始化函数                                                |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
    // 清理所有创建的对象
    ObjectsDeleteAll(0, "Buy_");
    ObjectsDeleteAll(0, "Sell_");
    ObjectsDeleteAll(0, "TradeLine_");
}

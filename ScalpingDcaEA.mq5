//+------------------------------------------------------------------+
//|                                               ScalpingDcaEA.mq5 |
//|                      Copyright 2024, Your Name (or Company)      |
//|                                      https://www.example.com |
//+------------------------------------------------------------------+
#property copyright "Copyright 2024, Your Name (or Company)"
#property link      "https://www.example.com"
#property version   "1.00"
#property description "A scalping EA with DCA for XAUUSD on MT5."

#include <Trade/Trade.mqh>

//--- Enums for trading strategies
enum EStrategy
{
   TREND,
   SIDEWAYS
};

//--- Input parameters
input group "Common Settings"
input double InpLots          = 0.01;      // Initial lot size
input int    InpStopLoss      = 0;         // Stop Loss in points (0 = disabled)
input double InpTakeProfit    = 10.0;      // Take Profit in account currency for the entire series
input int    InpMagicNumber   = 12345;     // Magic Number for orders

input group "Strategy Selection"
input int    InpAdxPeriod     = 14;        // ADX Period
input double InpAdxThreshold  = 25.0;      // ADX threshold to differentiate trend/sideways

input group "Trend Strategy (EMA Crossover)"
input int    InpFastEmaPeriod = 10;         // Fast EMA Period
input int    InpSlowEmaPeriod = 20;         // Slow EMA Period

input group "Sideways Strategy (Bollinger Bands)"
input int    InpBBandsPeriod  = 20;        // Bollinger Bands Period
input double InpBBandsDev     = 2.0;       // Bollinger Bands Deviation

input group "DCA Settings"
input bool   InpEnableDCA     = true;      // Enable DCA
input int    InpDcaDistance   = 500;       // Minimum distance in points between DCA trades
input double InpLotMultiplier = 1.5;       // Lot size multiplier for DCA trades
input int    InpMaxDcaOrders  = 5;         // Maximum number of DCA orders

//--- Global variables
CTrade trade;
EStrategy currentStrategy;
int adx_handle; // Handle for the ADX indicator
int fast_ema_handle; // Handle for the fast EMA
int slow_ema_handle; // Handle for the slow EMA
int bbands_handle; // Handle for the Bollinger Bands indicator

//+------------------------------------------------------------------+
//| Expert initialization function                                   |
//+------------------------------------------------------------------+
int OnInit()
{
   //--- Initialization of the trade object
   trade.SetExpertMagicNumber(InpMagicNumber);
   trade.SetMarginMode();
   trade.SetTypeFillingBySymbol(_Symbol);

   //--- Initialize indicators
   adx_handle = iADX(_Symbol, _Period, InpAdxPeriod);
   if(adx_handle == INVALID_HANDLE)
   {
      Print("Error creating ADX indicator handle");
      return(INIT_FAILED);
   }
   fast_ema_handle = iMA(_Symbol, _Period, InpFastEmaPeriod, 0, MODE_EMA, PRICE_CLOSE);
   if(fast_ema_handle == INVALID_HANDLE)
   {
      Print("Error creating Fast EMA indicator handle");
      return(INIT_FAILED);
   }
   slow_ema_handle = iMA(_Symbol, _Period, InpSlowEmaPeriod, 0, MODE_EMA, PRICE_CLOSE);
   if(slow_ema_handle == INVALID_HANDLE)
   {
      Print("Error creating Slow EMA indicator handle");
      return(INIT_FAILED);
   }
   bbands_handle = iBands(_Symbol, _Period, InpBBandsPeriod, 0, InpBBandsDev, PRICE_CLOSE);
   if(bbands_handle == INVALID_HANDLE)
   {
      Print("Error creating Bollinger Bands indicator handle");
      return(INIT_FAILED);
   }

   return(INIT_SUCCEEDED);
}

//+------------------------------------------------------------------+
//| Expert deinitialization function                                 |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
   //--- Deinitialize indicators
   IndicatorRelease(adx_handle);
   IndicatorRelease(fast_ema_handle);
   IndicatorRelease(slow_ema_handle);
   IndicatorRelease(bbands_handle);
}

//+------------------------------------------------------------------+
//| Expert tick function                                             |
//+------------------------------------------------------------------+
void OnTick()
{
   //--- Manage open positions (DCA and Take Profit) on every tick
   ManagePositions();

   //--- Check for new bar to open new trades
   if(IsNewBar())
   {
      //--- Determine the current market strategy
      DetermineStrategy();

      //--- Execute the corresponding strategy
      if(currentStrategy == TREND)
      {
         ExecuteTrendStrategy();
      }
      else
      {
         ExecuteSidewaysStrategy();
      }
   }
}

//+------------------------------------------------------------------+
//| Determines the current market strategy based on ADX              |
//+------------------------------------------------------------------+
void DetermineStrategy()
{
   double adx_value[];
   ArraySetAsSeries(adx_value, true);

   if(CopyBuffer(adx_handle, 0, 1, 1, adx_value) > 0)
   {
      if(adx_value[0] > InpAdxThreshold)
      {
         currentStrategy = TREND;
      }
      else
      {
         currentStrategy = SIDEWAYS;
      }
   }
   else
   {
      Print("Error copying ADX buffer");
      // Default to a strategy or do nothing
      currentStrategy = SIDEWAYS; // Default to sideways if ADX is not available
   }
}

//+------------------------------------------------------------------+
//| Executes the trend trading strategy                              |
//+------------------------------------------------------------------+
void ExecuteTrendStrategy()
{
   //--- Only open a new position if there are no open positions for this magic number
   if(HasOpenPositions())
      return;

   double fast_ema[3], slow_ema[3];
   MqlRates rates[2];
   ArraySetAsSeries(fast_ema, true);
   ArraySetAsSeries(slow_ema, true);
   ArraySetAsSeries(rates, true);

   //--- Get EMA values
   if(CopyBuffer(fast_ema_handle, 0, 0, 3, fast_ema) < 3 || CopyBuffer(slow_ema_handle, 0, 0, 3, slow_ema) < 3)
   {
      Print("Error copying EMA buffers");
      return;
   }

   //--- Get price data
   if(CopyRates(_Symbol, _Period, 0, 2, rates) < 2)
   {
      Print("Error copying rates");
      return;
   }

   //--- Buy Signal: Fast EMA crosses above Slow EMA on the closed bars, and the last closed bar pulls back to the Fast EMA
   if(fast_ema[2] < slow_ema[2] && fast_ema[1] > slow_ema[1]) // Crossover
   {
      if(rates[1].low <= fast_ema[1]) // Pullback
      {
         double price = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
         double sl = InpStopLoss > 0 ? price - InpStopLoss * _Point : 0;
         trade.Buy(InpLots, _Symbol, price, sl, 0, "Trend Buy");
      }
   }

   //--- Sell Signal: Fast EMA crosses below Slow EMA on the closed bars, and the last closed bar pulls back to the Fast EMA
   if(fast_ema[2] > slow_ema[2] && fast_ema[1] < slow_ema[1]) // Crossover
   {
      if(rates[1].high >= fast_ema[1]) // Pullback
      {
         double price = SymbolInfoDouble(_Symbol, SYMBOL_BID);
         double sl = InpStopLoss > 0 ? price + InpStopLoss * _Point : 0;
         trade.Sell(InpLots, _Symbol, price, sl, 0, "Trend Sell");
      }
   }
}

//+------------------------------------------------------------------+
//| Checks if there are any open positions for this EA               |
//+------------------------------------------------------------------+
bool HasOpenPositions()
{
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      if(PositionGetInteger(POSITION_MAGIC) == InpMagicNumber && PositionGetString(POSITION_SYMBOL) == _Symbol)
      {
         return(true);
      }
   }
   return(false);
}

//+------------------------------------------------------------------+
//| Checks if a new bar has started                                  |
//+------------------------------------------------------------------+
bool IsNewBar()
{
   static datetime last_bar_time = 0;
   datetime current_bar_time = (datetime)SeriesInfoInteger(_Symbol, _Period, SERIES_LASTBAR_DATE);

   if(last_bar_time != current_bar_time)
   {
      last_bar_time = current_bar_time;
      return(true);
   }
   return(false);
}

//+------------------------------------------------------------------+
//| Executes the sideways trading strategy                           |
//+------------------------------------------------------------------+
void ExecuteSidewaysStrategy()
{
   //--- Only open a new position if there are no open positions for this magic number
   if(HasOpenPositions())
      return;

   double upper_band[2], lower_band[2];
   MqlRates rates[2];
   ArraySetAsSeries(upper_band, true);
   ArraySetAsSeries(lower_band, true);
   ArraySetAsSeries(rates, true);


   //--- Get Bollinger Bands values
   if(CopyBuffer(bbands_handle, 1, 0, 2, upper_band) < 2 || CopyBuffer(bbands_handle, 2, 0, 2, lower_band) < 2)
   {
      Print("Error copying Bollinger Bands buffers");
      return;
   }

   //--- Get price data
   if(CopyRates(_Symbol, _Period, 0, 2, rates) < 2)
   {
      Print("Error copying rates");
      return;
   }

   //--- Buy Signal: Price on the last closed bar touches or crosses below the lower Bollinger Band
   if(rates[1].low <= lower_band[1])
   {
      double price = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
      double sl = InpStopLoss > 0 ? price - InpStopLoss * _Point : 0;
      trade.Buy(InpLots, _Symbol, price, sl, 0, "Sideways Buy");
   }

   //--- Sell Signal: Price on the last closed bar touches or crosses above the upper Bollinger Band
   if(rates[1].high >= upper_band[1])
   {
      double price = SymbolInfoDouble(_Symbol, SYMBOL_BID);
      double sl = InpStopLoss > 0 ? price + InpStopLoss * _Point : 0;
      trade.Sell(InpLots, _Symbol, price, sl, 0, "Sideways Sell");
   }
}

//+------------------------------------------------------------------+
//| Manages open positions (DCA and Take Profit)                     |
//+------------------------------------------------------------------+
void ManagePositions()
{
   double total_profit_buy = 0;
   double total_profit_sell = 0;
   int buy_positions_count = 0;
   int sell_positions_count = 0;
   ulong last_buy_ticket = 0;
   ulong last_sell_ticket = 0;
   double last_buy_open_price = 0;
   double last_sell_open_price = 0;
   double last_buy_lots = 0;
   double last_sell_lots = 0;
   datetime last_buy_open_time = 0;
   datetime last_sell_open_time = 0;

   //--- Iterate through all open positions
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(PositionGetInteger(POSITION_MAGIC) == InpMagicNumber && PositionGetString(POSITION_SYMBOL) == _Symbol)
      {
         if(PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_BUY)
         {
            total_profit_buy += PositionGetDouble(POSITION_PROFIT);
            buy_positions_count++;
            if((datetime)PositionGetInteger(POSITION_TIME) > last_buy_open_time)
            {
               last_buy_open_time = (datetime)PositionGetInteger(POSITION_TIME);
               last_buy_ticket = ticket;
               last_buy_open_price = PositionGetDouble(POSITION_PRICE_OPEN);
               last_buy_lots = PositionGetDouble(POSITION_VOLUME);
            }
         }
         else if(PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_SELL)
         {
            total_profit_sell += PositionGetDouble(POSITION_PROFIT);
            sell_positions_count++;
            if((datetime)PositionGetInteger(POSITION_TIME) > last_sell_open_time)
            {
               last_sell_open_time = (datetime)PositionGetInteger(POSITION_TIME);
               last_sell_ticket = ticket;
               last_sell_open_price = PositionGetDouble(POSITION_PRICE_OPEN);
               last_sell_lots = PositionGetDouble(POSITION_VOLUME);
            }
         }
      }
   }

   //--- Check for take profit for buy positions
   if(buy_positions_count > 0 && total_profit_buy >= InpTakeProfit)
   {
      CloseAllPositions(POSITION_TYPE_BUY);
   }

   //--- Check for take profit for sell positions
   if(sell_positions_count > 0 && total_profit_sell >= InpTakeProfit)
   {
      CloseAllPositions(POSITION_TYPE_SELL);
   }

   //--- DCA logic for buy positions
   if(InpEnableDCA && buy_positions_count > 0 && buy_positions_count < InpMaxDcaOrders && total_profit_buy < 0)
   {
      double current_price = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
      if(last_buy_open_price - current_price >= InpDcaDistance * _Point)
      {
         double sl = InpStopLoss > 0 ? current_price - InpStopLoss * _Point : 0;
         trade.Buy(last_buy_lots * InpLotMultiplier, _Symbol, current_price, sl, 0, "DCA Buy");
      }
   }

   //--- DCA logic for sell positions
   if(InpEnableDCA && sell_positions_count > 0 && sell_positions_count < InpMaxDcaOrders && total_profit_sell < 0)
   {
      double current_price = SymbolInfoDouble(_Symbol, SYMBOL_BID);
      if(current_price - last_sell_open_price >= InpDcaDistance * _Point)
      {
         double sl = InpStopLoss > 0 ? current_price + InpStopLoss * _Point : 0;
         trade.Sell(last_sell_lots * InpLotMultiplier, _Symbol, current_price, sl, 0, "DCA Sell");
      }
   }
}

//+------------------------------------------------------------------+
//| Closes all positions of a specific type                          |
//+------------------------------------------------------------------+
void CloseAllPositions(ENUM_POSITION_TYPE type)
{
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      if(PositionGetInteger(POSITION_MAGIC) == InpMagicNumber && PositionGetString(POSITION_SYMBOL) == _Symbol && PositionGetInteger(POSITION_TYPE) == type)
      {
         trade.PositionClose(PositionGetTicket(i));
      }
   }
}

//+------------------------------------------------------------------+
//|                                                        Bot.mq5 |
//|                        Copyright 2024, MetaQuotes Software Corp. |
//|                                             https://www.mql5.com |
//+------------------------------------------------------------------+
#property copyright "Copyright 2024, MetaQuotes Software Corp."
#property link      "https://www.mql5.com"
#property version   "1.00"

#include <Trade\Trade.mqh>

//--- input parameters

// MA SETUP
input ENUM_TIMEFRAMES   ma_timeframe = PERIOD_CURRENT;
input int               ma_period = 10;
input ENUM_MA_METHOD    ma_method = MODE_EMA;
input ENUM_APPLIED_PRICE ma_price = PRICE_OPEN;
input int               ma_shift = 0;

// HI-LO SETUP
input bool              hilo_enable = true;
input bool              hilo_invert = false;
input ENUM_TIMEFRAMES   hilo_timeframe = PERIOD_CURRENT;
input int               hilo_period = 3;
input ENUM_MA_METHOD    hilo_method = MODE_EMA;
input int               hilo_shift = 0;

// TRAILING STOP
input bool              trailing_stop_enable = true;
input int               trailing_start = 20;
input int               trailing_size = 20;

// BREAKEVEN
input bool              breakeven_enable = false;
input int               breakeven_start = 15;
input int               breakeven_step = 3;

// Filter Spread
input int               max_spread_pips = 240;

// DAILY LIMITS
input int               max_trades = 0;
input double            max_lots = 0.0;

// Range of Price
input bool              range_of_price_enable = false;
input double            range_distance = 10.0;

// DCA/Grid settings
input double            initial_lot_size = 0.01;
input int               grid_distance_pips = 20;
input double            lot_multiplier = 1.5;
input int               max_dca_orders = 5;
input int               take_profit_pips = 100;


//--- global variables
CTrade trade;
int ma_handle;
int hilo_high_handle;
int hilo_low_handle;
double initial_range_price = 0;

//+------------------------------------------------------------------+
//| Expert initialization function                                   |
//+------------------------------------------------------------------+
int OnInit()
  {
//--- create indicator handles
   ma_handle = iMA(_Symbol, ma_timeframe, ma_period, ma_shift, ma_method, ma_price);
   if(ma_handle == INVALID_HANDLE)
     {
      Print("Failed to create MA indicator. Error: ", GetLastError());
      return(INIT_FAILED);
     }

   if(hilo_enable)
     {
      hilo_high_handle = iMA(_Symbol, hilo_timeframe, hilo_period, hilo_shift, hilo_method, PRICE_HIGH);
      hilo_low_handle = iMA(_Symbol, hilo_timeframe, hilo_period, hilo_shift, hilo_method, PRICE_LOW);
      if(hilo_high_handle == INVALID_HANDLE || hilo_low_handle == INVALID_HANDLE)
        {
         Print("Failed to create HI-LO indicators. Error: ", GetLastError());
         return(INIT_FAILED);
        }
     }

   initial_range_price = 0; // Reset for range filter

   return(INIT_SUCCEEDED);
  }
//+------------------------------------------------------------------+
//| Expert deinitialization function                                 |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
  {
//--- release indicator handles
   IndicatorRelease(ma_handle);
   if(hilo_enable)
     {
      IndicatorRelease(hilo_high_handle);
      IndicatorRelease(hilo_low_handle);
     }
  }
//+------------------------------------------------------------------+
//| Helper functions                                                 |
//+------------------------------------------------------------------+
int CountOpenPositions(ENUM_POSITION_TYPE type)
{
    int count = 0;
    for(int i = PositionsTotal() - 1; i >= 0; i--)
    {
        if(PositionGetSymbol(i) == _Symbol)
        {
            if(PositionGetInteger(POSITION_TYPE) == type)
            {
                count++;
            }
        }
    }
    return count;
}

double GetLastOrderOpenPrice(ENUM_POSITION_TYPE type)
{
    double last_price = 0;
    ulong last_time = 0;
    for(int i = PositionsTotal() - 1; i >= 0; i--)
    {
        if(PositionGetSymbol(i) == _Symbol && PositionGetInteger(POSITION_TYPE) == type)
        {
            if(PositionGetInteger(POSITION_TIME) > last_time)
            {
                last_time = PositionGetInteger(POSITION_TIME);
                last_price = PositionGetDouble(POSITION_PRICE_OPEN);
            }
        }
    }
    return last_price;
}

double GetNextLotSize(ENUM_POSITION_TYPE type)
{
    double last_lot = 0;
    ulong last_time = 0;
    for(int i = PositionsTotal() - 1; i >= 0; i--)
    {
        if(PositionGetSymbol(i) == _Symbol && PositionGetInteger(POSITION_TYPE) == type)
        {
            if(PositionGetInteger(POSITION_TIME) > last_time)
            {
                last_time = PositionGetInteger(POSITION_TIME);
                last_lot = PositionGetDouble(POSITION_VOLUME);
            }
        }
    }
    return (last_lot == 0) ? initial_lot_size : NormalizeDouble(last_lot * lot_multiplier, 2);
}

void UpdatePositionsTakeProfit()
{
    double total_volume = 0;
    double weighted_price_sum = 0;
    ENUM_POSITION_TYPE position_type = (ENUM_POSITION_TYPE)-1;

    for(int i = PositionsTotal() - 1; i >= 0; i--)
    {
        if(PositionGetSymbol(i) == _Symbol)
        {
            double volume = PositionGetDouble(POSITION_VOLUME);
            double open_price = PositionGetDouble(POSITION_PRICE_OPEN);
            total_volume += volume;
            weighted_price_sum += open_price * volume;
            if(position_type == (ENUM_POSITION_TYPE)-1)
                position_type = (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);
        }
    }

    if(total_volume == 0) return;

    double vwap = weighted_price_sum / total_volume;
    double point = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
    double tp_price = 0;

    if(position_type == POSITION_TYPE_BUY)
    {
        tp_price = vwap + take_profit_pips * point;
    }
    else if(position_type == POSITION_TYPE_SELL)
    {
        tp_price = vwap - take_profit_pips * point;
    }

    for(int i = PositionsTotal() - 1; i >= 0; i--)
    {
        if(PositionGetSymbol(i) == _Symbol)
        {
            long ticket = PositionGetTicket(i);
            double sl = PositionGetDouble(POSITION_SL);
            trade.PositionModify(ticket, sl, tp_price);
        }
    }
}

//+------------------------------------------------------------------+
//| Risk Management Function                                         |
//+------------------------------------------------------------------+
void ManageRisk()
{
    // Do nothing if both are disabled
    if(!trailing_stop_enable && !breakeven_enable)
        return;

    double point = SymbolInfoDouble(_Symbol, SYMBOL_POINT);

    for(int i = PositionsTotal() - 1; i >= 0; i--)
    {
        if(PositionGetSymbol(i) != _Symbol)
            continue; // Not for this symbol

        long ticket = PositionGetTicket(i);
        double open_price = PositionGetDouble(POSITION_PRICE_OPEN);
        double current_sl = PositionGetDouble(POSITION_SL);
        double current_tp = PositionGetDouble(POSITION_TP);
        ENUM_POSITION_TYPE type = (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);

        double price_for_profit_calc = (type == POSITION_TYPE_BUY) ? SymbolInfoDouble(_Symbol, SYMBOL_BID) : SymbolInfoDouble(_Symbol, SYMBOL_ASK);
        double profit_pips = 0;

        if(type == POSITION_TYPE_BUY)
            profit_pips = (price_for_profit_calc - open_price) / point;
        else
            profit_pips = (open_price - price_for_profit_calc) / point;

        // --- Breakeven Logic ---
        if(breakeven_enable && profit_pips >= breakeven_start)
        {
            double new_sl = 0;
            if(type == POSITION_TYPE_BUY)
            {
                new_sl = open_price + breakeven_step * point;
                if(current_sl < new_sl)
                {
                    trade.PositionModify(ticket, new_sl, current_tp);
                    continue;
                }
            }
            else // SELL
            {
                new_sl = open_price - breakeven_step * point;
                if(current_sl > new_sl || current_sl == 0)
                {
                    trade.PositionModify(ticket, new_sl, current_tp);
                    continue;
                }
            }
        }

        // --- Trailing Stop Logic ---
        if(trailing_stop_enable && profit_pips >= trailing_start)
        {
            double new_sl = 0;
            if(type == POSITION_TYPE_BUY)
            {
                new_sl = price_for_profit_calc - trailing_size * point;
                if(current_sl < new_sl)
                {
                    trade.PositionModify(ticket, new_sl, current_tp);
                }
            }
            else // SELL
            {
                new_sl = price_for_profit_calc + trailing_size * point;
                if(current_sl > new_sl || current_sl == 0)
                {
                    trade.PositionModify(ticket, new_sl, current_tp);
                }
            }
        }
    }
}


//+------------------------------------------------------------------+
//| Expert tick function                                             |
//+------------------------------------------------------------------+
void OnTick()
{
    //--- Always run position management first
    if(PositionsTotal() > 0)
    {
        UpdatePositionsTakeProfit();
        ManageRisk();
    }

    //--- PRE-TRADE CHECKS for opening NEW positions ---

    //--- Get current prices for checks
    MqlTick latest_tick;
    if(!SymbolInfoTick(_Symbol, latest_tick)) return;
    double ask = latest_tick.ask;
    double bid = latest_tick.bid;
    double point = SymbolInfoDouble(_Symbol, SYMBOL_POINT);

    //--- 1. Check Spread
    if(SymbolInfoInteger(_Symbol, SYMBOL_SPREAD) > max_spread_pips) return;

    //--- 2. Check Range of Price
    if(range_of_price_enable)
    {
        if(initial_range_price == 0) initial_range_price = (ask + bid) / 2.0;
        if(ask > initial_range_price + range_distance || bid < initial_range_price - range_distance) return;
    }

    //--- 3. Check Max Trades
    int total_positions = PositionsTotal();
    if(max_trades > 0 && total_positions >= max_trades) return;

    //--- 4. Check Max Lots
    double current_lots = 0;
    for(int i = total_positions - 1; i >= 0; i--) {
        if(PositionGetSymbol(i) == _Symbol) {
            current_lots += PositionGetDouble(POSITION_VOLUME);
        }
    }

    //--- Passed all checks, now get indicator values for trading signals
    double ma_value[1];
    double hilo_high_value[1];
    double hilo_low_value[1];
    if(CopyBuffer(ma_handle, 0, 0, 1, ma_value) <= 0) return;
    if(hilo_enable && (CopyBuffer(hilo_high_handle, 0, 0, 1, hilo_high_value) <= 0 || CopyBuffer(hilo_low_handle, 0, 0, 1, hilo_low_value) <= 0)) return;

    //--- Initial Entry Logic
    if(total_positions == 0)
    {
        if(max_lots > 0 && initial_lot_size > max_lots) return;

        bool buy_signal = ask > ma_value[0] && (!hilo_enable || ask > hilo_high_value[0]);
        bool sell_signal = bid < ma_value[0] && (!hilo_enable || bid < hilo_low_value[0]);
        if(hilo_invert) { buy_signal = !buy_signal; sell_signal = !sell_signal; }

        if(buy_signal)
            trade.Buy(initial_lot_size, _Symbol, ask, 0, 0, "Initial Buy");
        else if(sell_signal)
            trade.Sell(initial_lot_size, _Symbol, bid, 0, 0, "Initial Sell");
    }
    //--- DCA/Grid Logic
    else
    {
        int buy_positions = CountOpenPositions(POSITION_TYPE_BUY);
        int sell_positions = CountOpenPositions(POSITION_TYPE_SELL);
        if(buy_positions > 0 && buy_positions < max_dca_orders)
        {
            double next_lot = GetNextLotSize(POSITION_TYPE_BUY);
            if(max_lots > 0 && current_lots + next_lot > max_lots) return;
            double last_buy_price = GetLastOrderOpenPrice(POSITION_TYPE_BUY);
            if(ask < last_buy_price - grid_distance_pips * point)
                trade.Buy(next_lot, _Symbol, ask, 0, 0, "DCA Buy");
        }
        else if(sell_positions > 0 && sell_positions < max_dca_orders)
        {
            double next_lot = GetNextLotSize(POSITION_TYPE_SELL);
            if(max_lots > 0 && current_lots + next_lot > max_lots) return;
            double last_sell_price = GetLastOrderOpenPrice(POSITION_TYPE_SELL);
            if(bid > last_sell_price + grid_distance_pips * point)
                trade.Sell(next_lot, _Symbol, bid, 0, 0, "DCA Sell");
        }
    }
}
//+------------------------------------------------------------------+

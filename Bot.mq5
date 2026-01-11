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

// Lot Size
input double            lot_size = 0.01;

//--- Equity Protection
enum ENUM_EQUITY_CLOSE_MODE
{
    AllTrades,      // All Trades
};
enum ENUM_DD_MODE
{
    EquityMoney,    // Equity Money
};

input ENUM_EQUITY_CLOSE_MODE equity_protection_close_mode = AllTrades;
input bool              close_chart = false;
input bool              turn_off_autotrade = false;
input bool              close_metatrader = false;
input double            max_floating_drawdown_money = 0.0;
input double            max_floating_drawdown_percentage = 0.0;
input double            min_equity = 0.0;
input ENUM_DD_MODE      max_dd_mode = EquityMoney;
input double            max_dd_per_day = 0.0;
input double            max_floating_profit_money = 0.0;
input double            max_floating_profit_percentage = 0.0;
input double            max_equity = 0.0;
input ENUM_DD_MODE      daily_target_mode = EquityMoney;
input double            daily_target = 0.0;

//--- Scheduler
input bool              use_time_filter = false;
input string            sunday_trading_hours = "";
input string            monday_trading_hours = "";
input string            tuesday_trading_hours = "";
input string            wednesday_trading_hours = "";
input string            thursday_trading_hours = "";
input string            friday_trading_hours = "";
input string            saturday_trading_hours = "";
input bool              close_all_trades_on_turn_off = true;


//--- global variables
CTrade trade;
int ma_handle;
bool g_trading_disabled_by_equity_protection = false;
bool g_outside_trading_hours = false;

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

   g_trading_disabled_by_equity_protection = false; // Reset on init

   return(INIT_SUCCEEDED);
  }
//+------------------------------------------------------------------+
//| Expert deinitialization function                                 |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
  {
//--- release indicator handles
   IndicatorRelease(ma_handle);

   //--- Close positions if setting is enabled when EA is removed
   if(reason != REASON_CHARTCHANGE && close_all_trades_on_turn_off)
   {
       Print("EA turning off. Closing all trades as per settings.");
       CloseAllPositions();
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
//| Equity Protection Helper Functions                               |
//+------------------------------------------------------------------+
void CloseAllPositions()
{
    // Close all open positions for the current symbol
    for(int i = PositionsTotal() - 1; i >= 0; i--)
    {
        if(PositionGetSymbol(i) == _Symbol)
        {
            trade.PositionClose(PositionGetTicket(i));
        }
    }
}

void CheckEquityProtection()
{
    if(g_trading_disabled_by_equity_protection)
        return;

    // Calculate floating P/L for the current symbol only
    double symbol_floating_pl = 0;
    for(int i = PositionsTotal() - 1; i >= 0; i--)
    {
        if(PositionGetSymbol(i) == _Symbol)
        {
            symbol_floating_pl += PositionGetDouble(POSITION_PROFIT);
        }
    }

    double equity = AccountInfoDouble(ACCOUNT_EQUITY);
    double balance = AccountInfoDouble(ACCOUNT_BALANCE);

    bool limit_reached = false;
    string trigger_reason = "";

    // Note: Min/Max Equity checks are account-wide by nature.
    // Check Min Equity
    if(min_equity > 0 && equity <= min_equity)
    {
        limit_reached = true;
        trigger_reason = "Minimum equity level reached.";
    }
    // Check Max Equity
    if(!limit_reached && max_equity > 0 && equity >= max_equity)
    {
        limit_reached = true;
        trigger_reason = "Maximum equity target reached.";
    }

    // The following checks are now based on the symbol's floating P/L
    // Check Max Floating Drawdown Money
    if(!limit_reached && max_floating_drawdown_money > 0 && symbol_floating_pl < 0 && -symbol_floating_pl >= max_floating_drawdown_money)
    {
        limit_reached = true;
        trigger_reason = "Maximum floating drawdown in money for " + _Symbol + " reached.";
    }
    // Check Max Floating Drawdown Percentage
    if(!limit_reached && max_floating_drawdown_percentage > 0 && balance > 0 && symbol_floating_pl < 0)
    {
        if(((-symbol_floating_pl / balance) * 100.0) >= max_floating_drawdown_percentage)
        {
            limit_reached = true;
            trigger_reason = "Maximum floating drawdown in percentage for " + _Symbol + " reached.";
        }
    }
    // Check Max Floating Profit Money
    if(!limit_reached && max_floating_profit_money > 0 && symbol_floating_pl >= max_floating_profit_money)
    {
        limit_reached = true;
        trigger_reason = "Maximum floating profit in money for " + _Symbol + " reached.";
    }
    // Check Max Floating Profit Percentage
    if(!limit_reached && max_floating_profit_percentage > 0 && balance > 0 && symbol_floating_pl > 0)
    {
        if(((symbol_floating_pl / balance) * 100.0) >= max_floating_profit_percentage)
        {
            limit_reached = true;
            trigger_reason = "Maximum floating profit in percentage for " + _Symbol + " reached.";
        }
    }

    if(limit_reached)
    {
        Print("Equity Protection Triggered on " + _Symbol + ": " + trigger_reason);
        CloseAllPositions(); // This function correctly closes positions only for the current symbol.

        if(turn_off_autotrade)
        {
            Print("Trading has been disabled by Equity Protection.");
            g_trading_disabled_by_equity_protection = true;
        }
        if(close_chart)
        {
            ChartClose();
        }
        if(close_metatrader)
        {
            TerminalClose();
        }
    }
}

//+------------------------------------------------------------------+
//| Time Filter Helper Function                                      |
//+------------------------------------------------------------------+
bool IsTradingAllowed()
{
    if(!use_time_filter)
        return true;

    MqlDateTime time_struct;
    TimeCurrent(time_struct);

    string trading_hours_today = "";
    switch(time_struct.day_of_week)
    {
        case 0: trading_hours_today = sunday_trading_hours; break;
        case 1: trading_hours_today = monday_trading_hours; break;
        case 2: trading_hours_today = tuesday_trading_hours; break;
        case 3: trading_hours_today = wednesday_trading_hours; break;
        case 4: trading_hours_today = thursday_trading_hours; break;
        case 5: trading_hours_today = friday_trading_hours; break;
        case 6: trading_hours_today = saturday_trading_hours; break;
    }

    if(trading_hours_today == "")
        return false; // No hours defined for today means no trading

    StringTrim(trading_hours_today);
    string sessions[];
    int num_sessions = StringSplit(trading_hours_today, ',', sessions);

    for(int i = 0; i < num_sessions; i++)
    {
        string parts[];
        if(StringSplit(sessions[i], '-', parts) != 2)
            continue; // Invalid format

        string start_time_str = parts[0];
        string end_time_str = parts[1];

        string start_parts[];
        string end_parts[];

        if(StringSplit(start_time_str, ':', start_parts) != 2 || StringSplit(end_time_str, ':', end_parts) != 2)
            continue; // Invalid format

        int start_hour = (int)StringToInteger(start_parts[0]);
        int start_min = (int)StringToInteger(start_parts[1]);
        int end_hour = (int)StringToInteger(end_parts[0]);
        int end_min = (int)StringToInteger(end_parts[1]);

        int current_time_in_minutes = time_struct.hour * 60 + time_struct.min;
        int start_time_in_minutes = start_hour * 60 + start_min;
        int end_time_in_minutes = end_hour * 60 + end_min;

        if(current_time_in_minutes >= start_time_in_minutes && current_time_in_minutes < end_time_in_minutes)
        {
            return true; // We are inside a valid session
        }
    }

    return false; // Not in any valid session
}


//+------------------------------------------------------------------+
//| Expert tick function                                             |
//+------------------------------------------------------------------+
void OnTick()
{
    if(g_trading_disabled_by_equity_protection)
    {
        Comment("TRADING DISABLED BY EQUITY PROTECTION");
        return;
    }

    //--- Check equity protection at the start of every tick
    CheckEquityProtection();

    //--- Check Time Filter
    if(!IsTradingAllowed())
    {
        if(close_all_trades_on_turn_off && !g_outside_trading_hours)
        {
            CloseAllPositions();
            Print("Trading session ended. Closing all positions.");
        }
        g_outside_trading_hours = true;
        Comment("OUTSIDE TRADING HOURS");
        return;
    }
    else
    {
        // Reset the flag when we re-enter a valid session
        g_outside_trading_hours = false;
        Comment(""); // Clear the comment
    }

    //--- Always run position management first
    if(PositionsTotal() > 0)
    {
        // Trailing stop is still relevant for the single position strategy
        ManageRisk();
    }

    //--- Check for new bar to execute trading logic once per bar ---
    static datetime last_bar_time = 0;
    datetime current_bar_time = (datetime)SeriesInfoInteger(_Symbol, Period(), SERIES_LASTBAR_DATE);

    if(current_bar_time <= last_bar_time)
    {
        return; // Not a new bar yet, exit
    }
    last_bar_time = current_bar_time; // It's a new bar, update the time

    //--- Get data for the most recently completed bar (index 1) ---
    double open_prices[1];
    double ma_values[1];
    if(CopyRates(_Symbol, Period(), 1, 1, open_prices) <= 0) return;
    if(CopyBuffer(ma_handle, 0, 1, 1, ma_values) <= 0) return;

    double bar_open = open_prices[0];
    double ema_value = ma_values[0];

    //--- Core Trading Logic: Always in the market ---

    // Get current market state
    MqlTick latest_tick;
    if(!SymbolInfoTick(_Symbol, latest_tick)) return;
    double ask = latest_tick.ask;
    double bid = latest_tick.bid;

    int buy_positions = CountOpenPositions(POSITION_TYPE_BUY);
    int sell_positions = CountOpenPositions(POSITION_TYPE_SELL);

    // Condition: Open price is ABOVE EMA -> We should be SELLING
    if(bar_open > ema_value)
    {
        // 1. Close any existing BUY positions
        if(buy_positions > 0)
        {
            for(int i = PositionsTotal() - 1; i >= 0; i--)
            {
                if(PositionGetSymbol(i) == _Symbol && PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_BUY)
                {
                    trade.PositionClose(PositionGetTicket(i));
                }
            }
        }
        // 2. Open a SELL position if there isn't one already
        if(CountOpenPositions(POSITION_TYPE_SELL) == 0)
        {
             if(SymbolInfoInteger(_Symbol, SYMBOL_SPREAD) <= max_spread_pips) // Check spread before opening
             {
                trade.Sell(lot_size, _Symbol, bid, 0, 0, "EMA Cross Sell");
             }
        }
    }
    // Condition: Open price is BELOW EMA -> We should be BUYING
    else if(bar_open < ema_value)
    {
        // 1. Close any existing SELL positions
        if(sell_positions > 0)
        {
            for(int i = PositionsTotal() - 1; i >= 0; i--)
            {
                if(PositionGetSymbol(i) == _Symbol && PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_SELL)
                {
                    trade.PositionClose(PositionGetTicket(i));
                }
            }
        }
        // 2. Open a BUY position if there isn't one already
        if(CountOpenPositions(POSITION_TYPE_BUY) == 0)
        {
             if(SymbolInfoInteger(_Symbol, SYMBOL_SPREAD) <= max_spread_pips) // Check spread before opening
             {
                trade.Buy(lot_size, _Symbol, ask, 0, 0, "EMA Cross Buy");
             }
        }
    }
}
//+------------------------------------------------------------------+

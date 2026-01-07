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
input double Lots         = 0.01;
input int    TakeProfit   = 50;
input int    StopLoss     = 50;

//--- global variables
CTrade trade;
double prev_price = 0;

//+------------------------------------------------------------------+
//| Expert initialization function                                   |
//+------------------------------------------------------------------+
int OnInit()
  {
//---
   return(INIT_SUCCEEDED);
  }
//+------------------------------------------------------------------+
//| Expert deinitialization function                                 |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
  {
//---

  }
//+------------------------------------------------------------------+
//| Expert tick function                                             |
//+------------------------------------------------------------------+
void OnTick()
  {
//--- check if a position is already open
   if(PositionSelect(_Symbol))
     {
      return;
     }

//--- get current prices
   MqlTick latest_tick;
   if(!SymbolInfoTick(_Symbol, latest_tick))
     {
      Print("SymbolInfoTick() failed, error code: ", GetLastError());
      return;
     }

   double ask = latest_tick.ask;
   double bid = latest_tick.bid;
   double point = SymbolInfoDouble(_Symbol, SYMBOL_POINT);

//--- initialize prev_price on the first tick
   if(prev_price == 0)
     {
      prev_price = (ask + bid) / 2;
      return;
     }

//--- trading logic
   if(ask > prev_price)
     {
      // Buy
      trade.Buy(Lots, _Symbol, ask, ask - StopLoss * point, ask + TakeProfit * point, "Buy Order");
     }
   else if(bid < prev_price)
     {
      // Sell
      trade.Sell(Lots, _Symbol, bid, bid + StopLoss * point, bid - TakeProfit * point, "Sell Order");
     }

//--- update previous price
   prev_price = (ask + bid) / 2;
  }
//+------------------------------------------------------------------+

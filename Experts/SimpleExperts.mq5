#property copyright   "Copyright 2009-2017, MetaQuotes Software Corp."
#property link        "http://www.mql5.com"
#property version     "5.50"
#property description "It is important to make sure that the expert works with a normal"
#property description "chart and the user did not make any mistakes setting input"
#property description "variables (Lots, TakeProfit, TrailingStop) in our case,"
#property description "we check TakeProfit on a chart of more than 2*trend_period bars"

#define MACD_MAGIC 1234502

#include <Trade\Trade.mqh>
#include <Trade\SymbolInfo.mqh>
#include <Trade\PositionInfo.mqh>
#include <Trade\AccountInfo.mqh>

input double InpLots          = 0.1; // Lots
input int    InpTakeProfit    = 50; // Take Profit (in pips)
input int    InpTrailingStop  = 30; // Trailing Stop Level (in pips)
input int    InpMACDOpenLevel = 3;  // MACD open level (in pips)
input int    InpMACDCloseLevel = 2; // MACD close level (in pips)
input int    InpMATrendPeriod = 26; // MA trend period

int ExtTimeOut = 10;

class FundManger
{
	virtual int Lot(CSymbolInfo &si) = 0;	
};

class Expert
{
public:
	bool Init(void)
	{
		return true;
	}
	
	virtual bool Processing(void) = 0;
	virtual bool LongOpened(void) = 0;
	virtual bool LongClosed(void) = 0;
	virtual bool LongModified(void) = 0;
	
	virtual bool ShortOpened(void) = 0;
	virtual bool ShortClosed(void) = 0;
	virtual bool ShortModified(void) = 0;

	virtual int OpenPolicy(CSymbolInfo &si) = 0;
	virtual double LotsCalc(CSymbolInfo &si) = 0;
	
	bool LotsCheck(CSymbolInfo &si, double lots)
	{
		if(lots < si.LotsMin() || lots > si.LotsMax()) {
			printf("Lots amount must be in the range from %f to %f",
				si.LotsMin(), si.LotsMax());
			return (false);
		}

		if(MathAbs(lots / si.LotsStep() - MathRound(lots / si.LotsStep())) > 1.0E-10) {
			printf("Lots amount is not corresponding with lot step %f", si.LotsStep());
			return (false);
		}

		return true;
	}
};

class COpenPolicy
{
	virtual bool policy(CSymbolInfo &si) = 0;
};

class MACDExpert: public Expert
{
	protected:
		double            m_adjusted_point; // point value adjusted for 3 or 5 points
		CTrade            m_trade;          // trading object
		CSymbolInfo       m_symbol;         // symbol info object
		CPositionInfo     m_position;       // trade position object
		CAccountInfo      m_account;        // account info wrapper

		// indicators
		int               m_handle_macd;    // MACD indicator handle
		int               m_handle_ema;     // moving average indicator handle

		// indicator buffers
		double            m_buff_MACD_main[];    // MACD indicator main buffer
		double            m_buff_MACD_signal[];  // MACD indicator signal buffer
		double            m_buff_EMA[];          // EMA indicator buffer

		// indicator data for processing
		double            m_macd_current;
		double            m_macd_previous;
		double            m_signal_current;
		double            m_signal_previous;
		double            m_ema_current;
		double            m_ema_previous;

		double            m_macd_open_level;
		double            m_macd_close_level;
		double            m_traling_stop;
		double            m_take_profit;

	public:
		MACDExpert(void);
		~MACDExpert(void);
		bool Init(void);
		void Deinit(void);
		bool Processing(void);
		bool LongClosed(void);
		bool ShortClosed(void);
		bool LongModified(void);
		bool ShortModified(void);
		bool LongOpened(void);
		bool ShortOpened(void);
		int OpenPolicy(CSymbolInfo &si);
		double LotsCalc(CSymbolInfo &si);

	protected:
		bool              InitCheckParameters(const int digits_adjust);
		bool              InitIndicators(void);
};

MACDExpert macdExpert;

MACDExpert::MACDExpert(void) : m_adjusted_point(0),
	m_handle_macd(INVALID_HANDLE),
	m_handle_ema(INVALID_HANDLE),
	m_macd_current(0),
	m_macd_previous(0),
	m_signal_current(0),
	m_signal_previous(0),
	m_ema_current(0),
	m_ema_previous(0),
	m_macd_open_level(0),
	m_macd_close_level(0),
	m_traling_stop(0),
	m_take_profit(0)
{
	ArraySetAsSeries(m_buff_MACD_main, true);
	ArraySetAsSeries(m_buff_MACD_signal, true);
	ArraySetAsSeries(m_buff_EMA, true);
}

MACDExpert::~MACDExpert(void)
{
}

bool MACDExpert::Init(void)
{
	m_symbol.Name(Symbol());
	m_trade.SetExpertMagicNumber(MACD_MAGIC);
	m_trade.SetMarginMode();
	m_trade.SetTypeFillingBySymbol(Symbol());

	// tuning for 3 or 5 digits
	int digits_adjust = 1;

	if(m_symbol.Digits() == 3 || m_symbol.Digits() == 5) {
		digits_adjust = 10;
	}

	m_adjusted_point = m_symbol.Point() * digits_adjust;
	// set default deviation for trading in adjusted points
	m_macd_open_level = InpMACDOpenLevel * m_adjusted_point;
	m_macd_close_level = InpMACDCloseLevel * m_adjusted_point;
	m_traling_stop    = InpTrailingStop * m_adjusted_point;
	m_take_profit     = InpTakeProfit * m_adjusted_point;
	// set default deviation for trading in adjusted points
	m_trade.SetDeviationInPoints(3 * digits_adjust);

	if(!InitCheckParameters(digits_adjust)) {
		return (false);
	}

	if(!InitIndicators()) {
		return (false);
	}

	return (true);
}

bool MACDExpert::InitCheckParameters(const int digits_adjust)
{
	if(InpTakeProfit * digits_adjust < m_symbol.StopsLevel()) {
		printf("Take Profit must be greater than %d", m_symbol.StopsLevel());
		return (false);
	}

	if(InpTrailingStop * digits_adjust < m_symbol.StopsLevel()) {
		printf("Trailing Stop must be greater than %d", m_symbol.StopsLevel());
		return (false);
	}

	if (LotsCheck(m_symbol, InpLots)) {
		return false;
	}

	if(InpTakeProfit <= InpTrailingStop) {
		printf("Warning: Trailing Stop must be less than Take Profit");
	}

	return (true);
}

bool MACDExpert::InitIndicators(void)
{
	if(m_handle_macd == INVALID_HANDLE) {
		if((m_handle_macd = iMACD(NULL, 0, 12, 26, 9, PRICE_CLOSE)) == INVALID_HANDLE) {
			printf("Error creating MACD indicator");
			return (false);
		}
	}

	if(m_handle_ema == INVALID_HANDLE) {
		if((m_handle_ema = iMA(NULL, 0, InpMATrendPeriod, 0, MODE_EMA, PRICE_CLOSE)) == INVALID_HANDLE) {
			printf("Error creating EMA indicator");
			return (false);
		}
	}

	return (true);
}

bool MACDExpert::LongClosed(void)
{
	bool res = false;

	if(m_macd_current > 0) {
		if(m_macd_current < m_signal_current && m_macd_previous > m_signal_previous) {
			if(m_macd_current > m_macd_close_level) {
				if(m_trade.PositionClose(Symbol())) {
					printf("Long position by %s to be closed", Symbol());
				} else {
					printf("Error closing position by %s : '%s'", Symbol(), m_trade.ResultComment());
				}

				res = true;
			}
		}
	}

	return (res);
}

bool MACDExpert::ShortClosed(void)
{
	bool res = false;

	if(m_macd_current < 0) {
		if(m_macd_current > m_signal_current && m_macd_previous < m_signal_previous) {
			if(MathAbs(m_macd_current) > m_macd_close_level) {
				if(m_trade.PositionClose(Symbol())) {
					printf("Short position by %s to be closed", Symbol());
				} else {
					printf("Error closing position by %s : '%s'", Symbol(), m_trade.ResultComment());
				}

				res = true;
			}
		}
	}

	return (res);
}

bool MACDExpert::LongModified(void)
{
	bool res = false;

	if(InpTrailingStop > 0) {
		if(m_symbol.Bid() - m_position.PriceOpen() > m_adjusted_point * InpTrailingStop) {
			double sl = NormalizeDouble(m_symbol.Bid() - m_traling_stop, m_symbol.Digits());
			double tp = m_position.TakeProfit();

			if(m_position.StopLoss() < sl || m_position.StopLoss() == 0.0) {
				if(m_trade.PositionModify(Symbol(), sl, tp)) {
					printf("Long position by %s to be modified", Symbol());
				} else {
					printf("Error modifying position by %s : '%s'",
							Symbol(), m_trade.ResultComment());
					printf("Modify parameters : SL=%f,TP=%f", sl, tp);
				}

				res = true;
			}
		}
	}

	return (res);
}

bool MACDExpert::ShortModified(void)
{
	bool res = false;

	if(InpTrailingStop > 0) {
		if((m_position.PriceOpen() - m_symbol.Ask()) > (m_adjusted_point * InpTrailingStop)) {
			double sl = NormalizeDouble(m_symbol.Ask() + m_traling_stop, m_symbol.Digits());
			double tp = m_position.TakeProfit();

			if(m_position.StopLoss() > sl || m_position.StopLoss() == 0.0) {
				if(m_trade.PositionModify(Symbol(), sl, tp)) {
					printf("Short position by %s to be modified", Symbol());
				} else {
					printf("Error modifying position by %s : '%s'",
							Symbol(), m_trade.ResultComment());
					printf("Modify parameters : SL=%f,TP=%f", sl, tp);
				}

				res = true;
			}
		}
	}

	return (res);
}

bool MACDExpert::LongOpened(void)
{
	if (OpenPolicy(m_symbol) == 1) {
		double price = m_symbol.Ask();
		double tp = m_symbol.Bid() + m_take_profit;
		double lots = LotsCalc(m_symbol);

		if (!LotsCheck(m_symbol, lots))
			return false;
		
		if(m_account.FreeMarginCheck(Symbol(), ORDER_TYPE_BUY, lots, price) < 0.0) {
			printf("We have no money. Free Margin = %f", m_account.FreeMargin());
		} else {
			if(m_trade.PositionOpen(Symbol(), ORDER_TYPE_BUY, lots, price, 0.0, tp)) {
				printf("Position by %s to be opened", Symbol());
			} else {
				printf("Error opening BUY position by %s : '%s'",
						Symbol(), m_trade.ResultComment());
				printf("Open parameters : price=%f,TP=%f", price, tp);
			}
		}

		return true;
	}

	return false;
}

bool MACDExpert::ShortOpened(void)
{
	if (OpenPolicy(m_symbol) == -1) {
		double price = m_symbol.Bid();
		double tp   = m_symbol.Ask() - m_take_profit;
		double lots = LotsCalc(m_symbol);

		if (!LotsCheck(m_symbol, lots))
			return false;

		if(m_account.FreeMarginCheck(Symbol(), ORDER_TYPE_SELL, lots, price) < 0.0) {
			printf("We have no money. Free Margin = %f", m_account.FreeMargin());
		} else {
			if(m_trade.PositionOpen(Symbol(), ORDER_TYPE_SELL, lots, price, 0.0, tp)) {
				printf("Position by %s to be opened", Symbol());
			} else {
				printf("Error opening SELL position by %s : '%s'",
						Symbol(), m_trade.ResultComment());
				printf("Open parameters : price=%f,TP=%f", price, tp);
			}
		}

		return true;
	}

	return false;
}

int MACDExpert::OpenPolicy(CSymbolInfo & si)
{
 	if(m_macd_current <= 0) 
		return 0;
	
	if(m_macd_current < m_signal_current && m_macd_previous > m_signal_previous) {
		if(m_macd_current > (m_macd_open_level) && m_ema_current < m_ema_previous) {
			return -1;
		}
	}

	if(m_macd_current > m_signal_current && m_macd_previous < m_signal_previous) {
		if(MathAbs(m_macd_current) > (m_macd_open_level) && m_ema_current > m_ema_previous) {
			return 1;
		}
	}
	
	return 0;
}
 
double MACDExpert::LotsCalc(CSymbolInfo &si)
{
	return 0.1;
}

bool MACDExpert::Processing(void)
{
	if(!m_symbol.RefreshRates()) {
		return (false);
	}

	if(BarsCalculated(m_handle_macd) < 2 || BarsCalculated(m_handle_ema) < 2) {
		return (false);
	}

	if(CopyBuffer(m_handle_macd, 0, 0, 2, m_buff_MACD_main) != 2 ||
			CopyBuffer(m_handle_macd, 1, 0, 2, m_buff_MACD_signal) != 2 ||
			CopyBuffer(m_handle_ema, 0, 0, 2, m_buff_EMA) != 2) {
		return (false);
	}

	m_macd_current   = m_buff_MACD_main[0];
	m_macd_previous  = m_buff_MACD_main[1];
	m_signal_current = m_buff_MACD_signal[0];
	m_signal_previous = m_buff_MACD_signal[1];
	m_ema_current    = m_buff_EMA[0];
	m_ema_previous   = m_buff_EMA[1];

	/*
	   it is important to enter the market correctly,
	   but it is more important to exit it correctly...
	   first check if position exists - try to select it
	 */
	if(m_position.Select(Symbol())) {
		if(m_position.PositionType() == POSITION_TYPE_BUY) {
			if(LongClosed()) {
				return (true);
			}

			if(LongModified()) {
				return (true);
			}
		} else {
			if(ShortClosed()) {
				return (true);
			}

			if(ShortModified()) {
				return (true);
			}
		}
	} else {
		if(LongOpened()) {
			return (true);
		}

		if(ShortOpened()) {
			return (true);
		}
	}

	return (false);
}

int OnInit(void)
{
	if(!macdExpert.Init()) {
		return (INIT_FAILED);
	}

	return (INIT_SUCCEEDED);
}

void OnTick(void)
{
	static datetime limit_time = 0; // last trade processing time + timeout

	if(TimeCurrent() >= limit_time) {
		if(Bars(Symbol(), Period()) > 2 * InpMATrendPeriod) {
			if(macdExpert.Processing()) {
				limit_time = TimeCurrent() + ExtTimeOut;
			}
		}
	}

	if(1) {
		return ;
	}
}

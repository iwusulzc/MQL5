#property copyright   "Copyright 2009-2017, MetaQuotes Software Corp."
#property link        "http://www.mql5.com"
#property version     "5.50"
#property description "It is important to make sure that the expert works with a normal"
#property description "chart and the user did not make any mistakes setting input"
#property description "variables (Lots, TakeProfit, TrailingStop) in our case,"
#property description "we check TakeProfit on a chart of more than 2*trend_period bars"

#define MAGIC 1234502

#include <Trade\Trade.mqh>
#include <Trade\SymbolInfo.mqh>
#include <Trade\PositionInfo.mqh>
#include <Trade\AccountInfo.mqh>

class CapitalManagent
{
public:
	double mInitFreeMargin;
	
private:
	CAccountInfo m_account;       // account info wrapper
	
public:
	CapitalManagent()
	{
		mInitFreeMargin = 0;
	}
	
	CapitalManagent(double initFreeMargin)
	{
		mInitFreeMargin = initFreeMargin;
	}

	virtual int Lot(CSymbolInfo &si, double openPrice) = 0;	
	
private:
	double FreeMargin(const string symbol,const ENUM_ORDER_TYPE trade_operation,
					const double volume,const double price)
	{
		return m_account.FreeMarginCheck(symbol, trade_operation, volume, price);
	}
};

class SimpleCapitalManagent : public CapitalManagent
{
public:
	SimpleCapitalManagent()
	{
	}
	
	SimpleCapitalManagent(double initFreeMargin) : CapitalManagent(initFreeMargin)
	{
	}
	
	int Lot(CSymbolInfo &si, double openPrice)
	{
		return 1;
	}
};

class PolicyParam
{
private:
	ENUM_ORDER_TYPE m_order_type;

	double m_price;
	double m_sl;    // STOP LOSS
	double m_tp;    // Target Profit

public:
	ENUM_ORDER_TYPE order_type_get(void)
	{
		return m_order_type;
	}
	
	void order_type_set(ENUM_ORDER_TYPE order_type)
	{
		m_order_type = order_type;
	}
	
	double price_get(void)
	{
		return m_price;
	}
	
	void price_set(double price)
	{
		m_price = price;
	}
	
	double sl_get(void)
	{
		return m_sl;
	}
	
	void sl_set(double sl)
	{
		m_sl = sl;
	}
	
	double tp_get(void)
	{
		return m_tp;
	}
	
	void tp_set(double tp)
	{
		m_tp = tp;
	}
	
};

class Policy
{
public:
	virtual void policy(const string symbol, PolicyParam &pp) = 0;
	virtual bool checkColse(void) = 0; // call after PositionSelect check for close
};

class SimplePolicy : public Policy
{
private:
	int m_ma10;
	int m_ma30;
	
public:
	SimplePolicy()
	{
		m_ma10 = iMA(NULL, 0, 10, 0, MODE_SMA, PRICE_CLOSE);
		m_ma30 = iMA(NULL, 0, 30, 0, MODE_SMA, PRICE_CLOSE);
	}
	
	void policy(const string symbol, PolicyParam &pp)
	{
		double pre_price, price;
		double point;
		double ma[1];
		
		CopyBuffer(m_ma30, 0, 0, 1, ma);
		pre_price = iClose(NULL, 0, 1);
		
		pp.price_set(0);
		
		if (pre_price > ma[0]) {
			price = SymbolInfoDouble(symbol, SYMBOL_ASK);
			if (price < 0.00001)
				return;
			point = price - ma[0];
			if (point < 500 * Point())
				return;
			pp.order_type_set(ORDER_TYPE_BUY);
			pp.price_set(price);
			pp.sl_set(ma[0]);
			pp.tp_set(price + (price - ma[0]) * 1);
		} else {
			price = SymbolInfoDouble(symbol, SYMBOL_BID);
			if (price < 0.00001)
				return;
			point = ma[0] - price;
			if (point < 500 * Point())
				return;
			pp.order_type_set(ORDER_TYPE_SELL);
			pp.price_set(price);
			pp.sl_set(ma[0]);
			pp.tp_set(price - (ma[0] - price) * 1);
		}
		
		pp.tp_set(0);
	}
	
	bool checkColse(void)
	{
		ENUM_POSITION_TYPE type;
		double pre_price;
		double ma[1];
		
		CopyBuffer(m_ma30, 0, 0, 1, ma);
		pre_price = iClose(NULL, 0, 1);
		
		type = (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);
		
		switch(type) {
		case POSITION_TYPE_BUY:
			if (pre_price < ma[0])
				return true;
			break;
		case POSITION_TYPE_SELL:
			if (pre_price > ma[0])
				return true;
			break;
		}
		
		return false;
	}
};

class Expert
{
public:
	CapitalManagent *m_cm;
	Policy *m_policy;
	CTrade *m_trade;
	CPositionInfo *m_position;
	
public:
	bool Init(void)
	{
		return true;
	}
	
	virtual bool Processing(void) = 0;
	
	virtual bool PositionOpen(void) = 0;
	virtual bool PositionClose(void) = 0;
	virtual bool PositionModify(void) = 0;
	
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

class SimpleExpert : public Expert
{
private:
	PolicyParam m_pp;
	
public:
	SimpleExpert()
	{
		m_cm = new SimpleCapitalManagent();
		m_policy = new SimplePolicy();
		m_trade = new CTrade();
		m_position = new CPositionInfo;
	}
	
	~SimpleExpert()
	{
		delete m_cm;
		delete m_policy;
		delete m_trade;
		delete m_position;
	}
	
	bool Init(void)
	{
		m_trade.SetExpertMagicNumber(MAGIC);
		m_trade.SetMarginMode();
		m_trade.SetTypeFillingBySymbol(Symbol());
		return true;
	}
	
	bool Processing(void)
	{
		m_policy.policy(Symbol(), &m_pp);
		
		if (!m_position.Select(Symbol())) {
			PositionOpen();
		} else {
			PositionModify();
			PositionClose();
		}
		
		return true;
	}
	
	bool PositionOpen(void)
	{
		if (m_pp.price_get() > 0) {
			if (!m_position.Select(Symbol())) {
				printf("OrderSend: odertype %d, price %f, sl %f, tp %f", 
						m_pp.order_type_get(), m_pp.price_get(),
						m_pp.sl_get(), m_pp.tp_get());
						
				m_trade.PositionOpen(Symbol(), m_pp.order_type_get(), 0.01, 
						m_pp.price_get(), m_pp.sl_get(), m_pp.tp_get(), 
						"new order...");
			}
		}
		
		return true;
	}
	
	bool PositionClose(void)
	{
		return true;
	}
	
	bool PositionModify(void)
	{
		if (m_policy.checkColse()) {
			m_trade.PositionClose(_Symbol, 3);
		}
		
		return true;
	}
};

SimpleExpert simpleExpert;
Expert *E;

int OnInit(void)
{
	E = &simpleExpert;
	
	if(!E.Init()) {
		return (INIT_FAILED);
	}

	return (INIT_SUCCEEDED);
}

void OnTick(void)
{
	E.Processing();
}
